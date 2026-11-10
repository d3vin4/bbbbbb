import SwiftUI

/// Khoá đánh dấu người dùng đã hoàn tất thiết lập lần đầu.
let onboardingCompletedKey = "bbbbbb.onboarding.completed"

/// Màn thiết lập lần mở app: ngôn ngữ → giới thiệu → chọn cơ chế truy cập →
/// (nếu chọn AirLift) hướng dẫn thiết lập AirLift riêng.
struct OnboardingView: View {
    @AppStorage(onboardingCompletedKey) private var isCompleted = false
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .english
    @AppStorage(AccessMethod.storageKey) private var accessMethod: AccessMethod = .auto

    @ObservedObject private var pairing = PairingController.shared
    @ObservedObject private var tunnel = TunnelManager.shared

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .language

    /// Mở lại từ Cài đặt (xem lại hướng dẫn) thay vì lần thiết lập đầu.
    var isReview: Bool = false

    enum Step: Int {
        case language
        case intro
        case method
        case airlift
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch step {
                        case .language:
                            languageStep
                        case .intro:
                            introStep
                        case .method:
                            methodStep
                        case .airlift:
                            airliftStep
                        }
                    }
                    .padding(24)
                }

                Divider()
                bottomBar
            }
            .navigationTitle(L.t("Thiết lập", "Setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isReview {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L.t("Đóng", "Close")) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bước 1: ngôn ngữ

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconBadge(systemImage: "globe")
            Text(L.t("Chọn ngôn ngữ", "Choose your language"))
                .font(.largeTitle.bold())
            Text(L.t(
                "Mặc định là English. Có thể đổi lại trong Cài đặt ▸ Giao diện.",
                "Default is English. You can change it later in Settings ▸ Interface."
            ))
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(AppLanguage.allCases) { option in
                    Button {
                        language = option
                    } label: {
                        HStack {
                            Text(option.title)
                                .font(.body)
                            Spacer()
                            if language == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if option != AppLanguage.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Bước 2: giới thiệu

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconBadge(systemImage: "internaldrive.fill")
            Text("bbbbbb")
                .font(.largeTitle.bold())
            Text(L.t(
                "Trình quản lý tệp cho iOS — liệt kê ứng dụng đã cài và mở container của từng ứng dụng mà không cần jailbreak.",
                "A file manager for iOS — list installed apps and open each app's container without jailbreak."
            ))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    systemImage: "square.grid.2x2",
                    title: L.t("Danh sách ứng dụng", "App list"),
                    detail: L.t("Tên, icon và container của mọi app trên máy.", "Name, icon and container of every app.")
                )
                featureRow(
                    systemImage: "folder",
                    title: L.t("Duyệt tệp", "Browse files"),
                    detail: L.t("Xem, sửa, sao chép, đổi tên, nén và xem tệp.", "View, edit, copy, rename, archive and preview files.")
                )
                featureRow(
                    systemImage: "sparkles",
                    title: L.t("Dọn Temp & Cache", "Clean temp"),
                    detail: L.t("Dọn file tạm của ứng dụng để giải phóng dung lượng.", "Clear app temp files to free up space.")
                )
            }
        }
    }

    // MARK: - Bước 3: chọn cơ chế

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconBadge(systemImage: "gearshape.2")
            Text(L.t("Chọn cách truy cập", "Choose how to access"))
                .font(.largeTitle.bold())
            Text(L.t(
                "Có thể đổi lại bất cứ lúc nào trong Cài đặt.",
                "You can change this anytime in Settings."
            ))
            .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                methodCard(
                    systemImage: "bolt.fill",
                    title: L.t("Trực tiếp", "Direct"),
                    detail: L.t("Đọc danh sách ứng dụng ngay trên máy. Không cần thiết lập gì thêm.", "Read the app list on-device. Nothing else to set up."),
                    isSelected: accessMethod == .direct
                ) {
                    accessMethod = .direct
                }

                methodCard(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "AirLift",
                    detail: L.t("Đọc danh sách qua AirLift — cần pair thiết bị + tunnel (màn thiết lập riêng).", "Read the list over AirLift — needs pairing + tunnel (separate setup screen)."),
                    isSelected: accessMethod == .airlift
                ) {
                    accessMethod = .airlift
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(L.t(
                    "Mở container và tệp bên trong ứng dụng luôn dùng worse_query — mặc định, không cần chỉnh.",
                    "Opening containers and files inside apps always uses worse_query — default, nothing to configure."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bước 4: thiết lập AirLift

    private var airliftStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            iconBadge(systemImage: "antenna.radiowaves.left.and.right")
            Text(L.t("Thiết lập AirLift", "Set up AirLift"))
                .font(.largeTitle.bold())
            Text(L.t(
                "AirLift dùng kênh RSD của hệ thống: cần pair thiết bị và bật tunnel loopback.",
                "AirLift uses the system RSD channel: pair the device and enable the loopback tunnel."
            ))
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                setupRow(
                    number: 1,
                    title: L.t("Pair thiết bị", "Pair the device"),
                    detail: L.t("Pair trực tiếp trên iPhone rồi nhập PIN trong Developer Mode.", "Pair on the iPhone, then enter the PIN in Developer Mode."),
                    isDone: pairing.hasPairingFile
                )

                Divider()

                setupRow(
                    number: 2,
                    title: L.t("Bật tunnel loopback", "Enable loopback tunnel"),
                    detail: L.t("Tunnel 10.7.0.1 để tới được dịch vụ hệ thống.", "The 10.7.0.1 tunnel that reaches system services."),
                    isDone: tunnel.isConnected
                )
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let pin = pairing.pairingPIN {
                Text(L.t("PIN: ", "PIN: ") + pin)
                    .font(.title2.monospaced().bold())
            }

            HStack(spacing: 12) {
                if pairing.running {
                    Button(L.t("Huỷ pairing", "Cancel pairing")) {
                        pairing.softCancel()
                    }
                } else {
                    Button(L.t("Pair thiết bị", "Pair device")) {
                        Task {
                            do {
                                _ = try await pairing.startAndWait()
                            } catch {
                                Log.error("Pairing lỗi: \(error.localizedDescription)", category: .pairing)
                            }
                        }
                    }
                }

                Button(L.t("Bật tunnel", "Enable tunnel")) {
                    Task {
                        await tunnel.load()
                        await tunnel.connect()
                    }
                }
                .disabled(tunnel.isConnected || tunnel.isBusy)
            }
            .buttonStyle(.borderedProminent)

            if let error = tunnel.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Thanh dưới

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .language {
                Button(L.t("Quay lại", "Back")) {
                    goBack()
                }
                .buttonStyle(.bordered)
            }

            Button(primaryTitle) {
                goNext()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    private var primaryTitle: String {
        switch step {
        case .language:
            return L.t("Tiếp tục", "Continue")
        case .intro:
            return L.t("Tiếp tục", "Continue")
        case .method:
            return L.t("Tiếp tục", "Continue")
        case .airlift:
            return L.t("Xong", "Done")
        }
    }

    private func goNext() {
        switch step {
        case .language:
            step = .intro
        case .intro:
            step = .method
        case .method:
            if accessMethod == .airlift {
                step = .airlift
            } else {
                finish()
            }
        case .airlift:
            finish()
        }
    }

    private func goBack() {
        switch step {
        case .language:
            break
        case .intro:
            step = .language
        case .method:
            step = .intro
        case .airlift:
            step = .method
        }
    }

    private func finish() {
        isCompleted = true
        if isReview {
            dismiss()
        }
    }

    // MARK: - Thành phần

    private func iconBadge(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 44))
            .foregroundStyle(.tint)
            .frame(width: 76, height: 76)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func featureRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func methodCard(
        systemImage: String,
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func setupRow(number: Int, title: String, detail: String, isDone: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}
