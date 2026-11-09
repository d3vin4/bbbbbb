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

            Section("Thông tin") {
                LabeledContent("Phiên bản", value: app.version.isEmpty ? "—" : app.version)
                LabeledContent("Loại", value: app.type)
                LabeledContent("Nguồn", value: app.source == .airlift ? "AirLift" : "Trực tiếp")
                if let path = app.path {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Container")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Button("Sao chép Bundle ID") {
                    UIPasteboard.general.string = app.bundleID
                }
            }

            Section("Hành động") {
                if app.source == .direct {
                    NavigationLink {
                        CleanTempView(focusBundleID: app.bundleID)
                    } label: {
                        Label("Dọn Temp & Cache", systemImage: "sparkles")
                    }
                    Button {
                        Task { await activateContainer() }
                    } label: {
                        if isWorking {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Đang xử lý…")
                            }
                        } else {
                            Text("Kích hoạt container (lease) và đọc thử")
                        }
                    }
                    .disabled(isWorking || app.path == nil)
                }

                if app.source == .airlift {
                    Button(role: .destructive) {
                        Task { await uninstall() }
                    } label: {
                        Text("Gỡ cài đặt")
                    }
                    .disabled(isWorking)
                }

                if let activatedPath {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Đã kích hoạt")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(activatedPath)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let localError {
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
        guard let path = app.path else { return }
        isWorking = true
        localError = nil
        defer { isWorking = false }

        do {
            let result = try await Task.detached { () -> (String, Int) in
                let record = ContainerRecord(identifier: app.bundleID, kind: .application, path: path)
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
