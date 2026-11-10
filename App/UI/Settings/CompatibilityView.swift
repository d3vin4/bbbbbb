import ActivityKit
import Darwin
import SwiftUI

/// Kiểm tra tương thích: từng module (worse_query/bad_query/Airlift/VPN/…) so
/// với dải phiên bản iOS đã xác minh, kèm trạng thái trực tiếp trên máy.
struct CompatibilityView: View {
    private struct Check: Identifiable {
        enum Status {
            case ok
            case warning
            case fail
        }

        let id = UUID()
        let title: String
        let status: Status
        let detail: String
    }

    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var pairing = PairingController.shared

    @State private var checks: [Check] = []

    var body: some View {
        List {
            Section("Thiết bị") {
                LabeledContent("iOS", value: Self.osVersionString)
                LabeledContent("Build", value: Self.osBuildString)
            }

            Section("Kết quả kiểm tra") {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.symbol(for: check.status))
                            .foregroundStyle(Self.color(for: check.status))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("Dải đã xác minh — worse_query: 26.0–26.7.2 & 27.0–27.2 (đường chính cho App Group/container, flags khác nhau giữa 26.x và 27.x) · bad_query: 26.0–26.6.1 / 27.0b4 (dự phòng khi thiếu App Group) · airlift/AirTraffic: bị Apple vá từ 27.2 beta 3 · pairing trong Settings: cần iOS 27+.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tương thích")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Quét lại") {
                    runChecks()
                }
            }
        }
        .task {
            runChecks()
        }
    }

    // MARK: - Checks

    private func runChecks() {
        var result: [Check] = []
        let version = ProcessInfo.processInfo.operatingSystemVersion

        // 1. iOS range
        if version.majorVersion == 26 {
            if version.minorVersion <= 7 {
                result.append(Check(
                    title: "Phiên bản iOS",
                    status: .ok,
                    detail: "iOS 26.\(version.minorVersion) nằm trong dải worse_query (26.0–26.7.2)."
                ))
            } else {
                result.append(Check(
                    title: "Phiên bản iOS",
                    status: .warning,
                    detail: "iOS 26.\(version.minorVersion) ngoài dải đã xác minh — vẫn thử được nhưng có thể đã bị vá."
                ))
            }
        } else if version.majorVersion == 27 {
            if version.minorVersion <= 2 {
                result.append(Check(
                    title: "Phiên bản iOS",
                    status: .ok,
                    detail: "iOS 27.\(version.minorVersion) nằm trong dải worse_query (27.0–27.2)."
                ))
            } else {
                result.append(Check(
                    title: "Phiên bản iOS",
                    status: .warning,
                    detail: "iOS 27.\(version.minorVersion) ngoài dải đã xác minh (tới 27.2) — exploit có thể đã bị vá."
                ))
            }
        } else {
            result.append(Check(
                title: "Phiên bản iOS",
                status: .fail,
                detail: "iOS \(version.majorVersion).\(version.minorVersion) ngoài dải hỗ trợ (26.0–27.2)."
            ))
        }

        // 2. Direct engine + MHA identity
        let report = DirectEngine.shared.capabilityReport()
        result.append(Check(
            title: "Trực tiếp — MCM / MHA-C2",
            status: report.mcmAvailable ? (report.mhaIdentity ? .ok : .warning) : .fail,
            detail: report.mhaIdentity
                ? "MCM khả dụng, bundle id MHA đúng."
                : (report.mcmAvailable
                    ? "MCM khả dụng nhưng bundle id chưa phải MHA — cần ký với identity com.apple.mobile.MobileHouseArrest."
                    : "Không nạp được libsystem_containermanager.")
        ))
        result.append(Check(
            title: "Đường escape chính",
            status: report.appGroups.isEmpty ? .warning : .ok,
            detail: report.route
        ))

        // 3. App Group entitlement
        result.append(Check(
            title: "App Group entitlement",
            status: report.appGroups.isEmpty ? .warning : .ok,
            detail: report.appGroups.isEmpty
                ? "Không có — worse_query (class-7) không chạy được; engine tự chuyển bad_query/class-2."
                : report.appGroups.joined(separator: ", ")
        ))

        // 4. bad_query fallback range
        if version.majorVersion == 26, version.minorVersion <= 6 {
            result.append(Check(
                title: "bad_query (dự phòng)",
                status: .ok,
                detail: "iOS ≤ 26.6.x nằm trong dải bad_query (26.0–26.6.1) — dùng khi thiếu App Group."
            ))
        } else if version.majorVersion == 27, version.minorVersion == 0 {
            result.append(Check(
                title: "bad_query (dự phòng)",
                status: .warning,
                detail: "27.0.x: một số build còn dùng được (27.0b4); 27.2 đã bị vá traversal."
            ))
        } else {
            result.append(Check(
                title: "bad_query (dự phòng)",
                status: .warning,
                detail: "Có thể đã bị vá trên build này — engine vẫn thử sau worse_query rồi tự chuyển class-2."
            ))
        }

        // 5. Airlift pairing
        if version.majorVersion >= 27 {
            result.append(Check(
                title: "Airlift pairing (Settings)",
                status: .ok,
                detail: "iOS 27+: Pair trực tiếp trong Settings ▸ Developer Mode (kèm PIN + Live Activity)."
            ))
        } else {
            result.append(Check(
                title: "Airlift pairing (Settings)",
                status: .warning,
                detail: "Cần iOS 27+; bản thấp hơn dùng file pairing import."
            ))
        }
        result.append(Check(
            title: "Pairing record",
            status: pairing.hasPairingFile ? .ok : .warning,
            detail: pairing.hasPairingFile
                ? "Đã có pairing."
                : "Chưa pair — InstallationProxy/AFC cần pairing."
        ))

        // 6. AirTraffic (airlift)
        if version.majorVersion >= 27, version.minorVersion >= 2 {
            result.append(Check(
                title: "Airlift AirTraffic",
                status: .warning,
                detail: "27.2+ (từ beta 3) Apple đã vá AirTraffic sync — AirLift dùng InstallationProxy/AFC, container dùng Trực tiếp."
            ))
        } else {
            result.append(Check(
                title: "Airlift AirTraffic",
                status: .ok,
                detail: "Trong dải hoạt động (< 27.2 beta 3)."
            ))
        }

        // 7. InstallationProxy readiness
        result.append(Check(
            title: "Cài/gỡ IPA (InstallationProxy)",
            status: (pairing.hasPairingFile && tunnel.isConnected) ? .ok : .warning,
            detail: (pairing.hasPairingFile && tunnel.isConnected)
                ? "Sẵn sàng (pairing + tunnel)."
                : "Cần có pairing và tunnel đang kết nối."
        ))

        // 8. Tunnel
        result.append(Check(
            title: "Tunnel loopback",
            status: tunnel.isConnected ? .ok : .warning,
            detail: tunnel.isConnected
                ? "Đang kết nối (10.7.0.1)."
                : "Chưa kết nối — bật trong Settings ▸ VPN (cần entitlement NetworkExtension khi ký)."
        ))

        // 9. Live Activity
        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        result.append(Check(
            title: "Live Activity (PIN)",
            status: activitiesEnabled ? .ok : .warning,
            detail: activitiesEnabled
                ? "Được phép hiển thị trên Dynamic Island/Lock Screen."
                : "Đang tắt — PIN vẫn hiển thị trong app khi pairing."
        ))

        checks = result
        for check in result {
            Log.info("[tương thích] \(check.title) — \(check.detail)", category: .app)
        }
    }

    // MARK: - Helpers

    private static var osVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var osBuildString: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "—" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func symbol(for status: Check.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private static func color(for status: Check.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }
}
