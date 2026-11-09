import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: LogStore
    @State private var searchText = ""
    @State private var levelFilter: LogLevel?

    private var filteredEntries: [LogEntry] {
        store.entries.reversed().filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if searchText.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
                LogEntryRow(entry: entry)
            }
            .listStyle(.plain)
            .navigationTitle("Logs")
            .searchable(text: $searchText, prompt: "Tìm trong logs")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Mức log", selection: $levelFilter) {
                            Text("Tất cả").tag(nil as LogLevel?)
                            ForEach(LogLevel.allCases) { level in
                                Text(level.label).tag(level as LogLevel?)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }

                    ShareLink(item: store.exportText) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        store.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .overlay {
                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "Không có log",
                        systemImage: "text.alignleft",
                        description: Text("Logs từ Airlift, BadQuery, VPN, Pairing và File Manager sẽ hiển thị tại đây.")
                    )
                }
            }
        }
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.symbolName)
                .foregroundStyle(levelColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                Text("\(entry.category.label) · \(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.level.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
