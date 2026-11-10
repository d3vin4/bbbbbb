import SwiftUI
import UIKit

struct AppDetailView: View {
    let app: CatalogApp
    @ObservedObject var catalog: AppCatalog

    @State private var isWorking = false
    @State private var localError: String?
    @State private var activatedPath: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    iconView
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        Text(app.bundleID)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L.t("Thông tin", "Info")) {
                LabeledContent(L.t("Loại", "Type"), value: app.type)
                if let path = app.path {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Container", "Container"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Button(L.t("Sao chép Bundle ID", "Copy Bundle ID")) {
                    UIPasteboard.general.string = app.bundleID
                }
            }

            Section(L.t("Hành động", "Actions")) {
                NavigationLink {
                    FileBrowserView(
                        root: ContainerRecord(identifier: app.bundleID, kind: .application, path: app.path ?? "")
                    )
                } label: {
                    Label(L.t("Mở Container", "Open Container"), systemImage: "folder")
                }
                NavigationLink {
                    CleanTempView(focusBundleID: app.bundleID)
                } label: {
                    Label(L.t("Dọn Temp & Cache", "Clean Temp & Cache"), systemImage: "sparkles")
                }
                Button {
                    Task { await activateContainer() }
                } label: {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L.t("Đang xử lý…", "Working…"))
                        }
                    } else {
                        Text(L.t("Kích hoạt container và đọc thử", "Activate container and test read"))
                    }
                }
                .disabled(isWorking)

                if AirliftEngine.shared.hasPairing {
                    Button(role: .destructive) {
                        Task { await uninstall() }
                    } label: {
                        Text(L.t("Gỡ cài đặt", "Uninstall"))
                    }
                    .disabled(isWorking)
                }
            }

            if let activatedPath {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Đã kích hoạt", "Activated"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(activatedPath)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            if let localError {
                Section {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = catalog.icons[app.bundleID] {
            Image(uiImage: image)
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 40))
                .frame(width: 52, height: 52)
                .foregroundStyle(.secondary)
        }
    }

    private func activateContainer() async {
        isWorking = true
        localError = nil
        defer { isWorking = false }

        do {
            let result = try await Task.detached { () -> (String, Int) in
                let record = ContainerRecord(identifier: app.bundleID, kind: .application, path: app.path ?? "")
                let activated = try DirectEngine.shared.activate(record)
                let entries = (try? DirectEngine.shared.listDirectory(at: activated)) ?? []
                return (activated, entries.count)
            }.value
            activatedPath = result.0
            Log.info("Direct: kích hoạt \(app.bundleID) → \(result.0) (\(result.1) mục)", category: .badquery)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func uninstall() async {
        isWorking = true
        localError = nil
        defer { isWorking = false }
        do {
            try await catalog.uninstall(app)
        } catch {
            localError = error.localizedDescription
        }
    }
}
