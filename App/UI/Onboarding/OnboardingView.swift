import SwiftUI
import UIKit

/// Khoá đánh dấu người dùng đã hoàn tất thiết lập lần đầu.
let onboardingCompletedKey = "bbbbbb.onboarding.completed"

/// Màn thiết lập lần mở app: chọn ngôn ngữ → giới thiệu → xong.
///
/// App chỉ dùng kỹ thuật **worse_query**: cần **một App Group entitlement**
/// trong profile ký (không cần identity MHA, không cần pairing/tunnel).
struct OnboardingView: View {
    @AppStorage(onboardingCompletedKey) private var isCompleted = false
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .english

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .language

    enum Step: Int {
        case language
        case intro
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
                        }
                    }
                    .padding(24)
                }

                Divider()
                bottomBar
            }
            .navigationTitle(L.t("Thiết lập", "Setup"))
            .navigationBarTitleDisplayMode(.inline)
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
                    detail: L.t("Tên, icon của mọi app trên máy.", "Name and icon of every app.")
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

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(L.t(
                    "Truy cập dùng kỹ thuật worse_query: profile ký cần một App Group entitlement (tên group không quan trọng).",
                    "Access uses the worse_query technique: the signing profile needs one App Group entitlement (any name works)."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Thanh dưới

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .language {
                Button(L.t("Quay lại", "Back")) {
                    step = .language
                }
                .buttonStyle(.bordered)
            }

            Button(step == .language ? L.t("Tiếp tục", "Continue") : L.t("Bắt đầu", "Get started")) {
                if step == .language {
                    step = .intro
                } else {
                    isCompleted = true
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
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
}
