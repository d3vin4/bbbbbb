import SwiftUI
import UniformTypeIdentifiers

/// Imports a pre-signed .ipa and installs it on the device through the AirLift
/// route (AFC staging + InstallationProxy).
struct InstallIPAView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var pickedURL: URL?
    @State private var pickedName = ""
    @State private var isInstalling = false
    @State private var progress: Double = 0
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("IPA đã ký sẵn") {
                    Button {
                        isImporting = true
                    } label: {
                        Label(
                            pickedURL == nil ? "Chọn file IPA…" : pickedName,
                            systemImage: "doc.badge.plus"
                        )
                    }
                    .disabled(isInstalling)

                    Text("bbbbbb không ký IPA. Hãy ký trước bằng eSign/cert của bạn rồi chọn file .ipa ở đây — ứng dụng sẽ upload qua AFC và cài bằng InstallationProxy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isInstalling {
                    Section("Tiến trình") {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await install() }
                    } label: {
                        if isInstalling {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Đang cài…")
                            }
                        } else {
                            Text("Cài đặt")
                        }
                    }
                    .disabled(pickedURL == nil || isInstalling)
                }
            }
            .navigationTitle("Cài IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                pickedURL = try copyToStaging(url)
                pickedName = url.lastPathComponent
                errorMessage = nil
                statusMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func copyToStaging(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPAdrop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func install() async {
        guard let pickedURL, !isInstalling else { return }
        isInstalling = true
        progress = 0
        errorMessage = nil
        statusMessage = "Đang cài đặt…"
        do {
            try await AirliftServices.shared.installIPA(at: pickedURL) { value in
                Task { @MainActor in
                    progress = value
                }
            }
            progress = 1
            statusMessage = "Đã cài đặt thành công."
            Log.info("InstallIPA: cài xong \(pickedName)", category: .airlift)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            Log.error("InstallIPA lỗi: \(error.localizedDescription)", category: .airlift)
        }
        isInstalling = false
    }
}
