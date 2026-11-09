import SwiftUI

struct AppsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Thiết bị") {
                    LabeledContent("Kết nối") {
                        Text("Chưa kết nối")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Hỗ trợ") {
                        Text(SupportMatrix.supportSummary)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("iOS hiện tại") {
                        Text(SupportMatrix.currentOSVersion)
                            .foregroundStyle(SupportMatrix.isRunningSupportedOS ? .secondary : Color.orange)
                    }
                }

                Section("Quy trình thiết lập Airlift") {
                    SetupStepRow(
                        number: 1,
                        title: "Bật tunnel nội bộ",
                        detail: "VPN loopback (10.7.0.1) để ứng dụng kết nối tới dịch vụ hệ thống — không cần cài LocalDevVPN riêng."
                    )
                    SetupStepRow(
                        number: 2,
                        title: "Pair thiết bị",
                        detail: "Mở màn Pairing để lấy mã PIN 6 số (hiển thị cả trên Live Activity), rồi nhập trong Settings ▸ Privacy & Security ▸ Developer Mode."
                    )
                    SetupStepRow(
                        number: 3,
                        title: "Duyệt dữ liệu",
                        detail: "Sau khi pairing + escape sẵn sàng, mở container ứng dụng và App Groups từ danh sách."
                    )
                }

                Section {
                    ContentUnavailableView(
                        "Chưa có dữ liệu ứng dụng",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Danh sách ứng dụng sẽ xuất hiện sau khi hoàn tất tích hợp Airlift + BadQuery.")
                    )
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
