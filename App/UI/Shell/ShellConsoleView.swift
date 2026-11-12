import SwiftUI

/// Shell mini trong app: bộ lệnh file (ls/cd/cat/cp/mv/rm/mkdir/df/…),
/// chạy trên engine worse_query (mọi đường dẫn đều qua ensureFileAccess).
/// iOS không cho exec tiến trình nên đây là shell nội bộ, không phải /bin/sh.
final class MiniShell {
    private(set) var cwd = NSHomeDirectory()
    private let fileManager = FileManager.default

    static let helpText = """
    Lệnh hỗ trợ:
      help            danh sách lệnh
      pwd             thư mục hiện tại
      ls [path]       liệt kê
      cd [path]       đổi thư mục
      cat <file>      in nội dung (tối đa 64 KB)
      head <file> [n] in n dòng đầu (mặc định 20)
      mkdir <dir>     tạo thư mục
      touch <file>    tạo file rỗng
      rm [-r] <path>  xoá
      cp <src> <dst>  sao chép
      mv <src> <dst>  di chuyển / đổi tên
      df [path]       dung lượng
      echo <text>     in text
      whoami · date
      clear           xoá màn hình
    """

    func run(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: " ").map(String.init)
        let command = parts[0].lowercased()
        let args = Array(parts.dropFirst())

        switch command {
        case "help":
            return Self.helpText
        case "pwd":
            return cwd
        case "ls":
            return list(args.first)
        case "cd":
            return changeDirectory(args.first)
        case "cat":
            guard let path = args.first else { return "cat: thiếu file" }
            return readFile(path, lines: nil)
        case "head":
            guard let path = args.first else { return "head: thiếu file" }
            let count = args.count > 1 ? Int(args[1]) ?? 20 : 20
            return readFile(path, lines: count)
        case "mkdir":
            guard let path = args.first else { return "mkdir: thiếu thư mục" }
            let full = resolve(path)
            _ = DirectEngine.shared.ensureFileAccess(full)
            do {
                try fileManager.createDirectory(atPath: full, withIntermediateDirectories: true)
                return "Đã tạo \(full)"
            } catch {
                return "mkdir: \(error.localizedDescription)"
            }
        case "touch":
            guard let path = args.first else { return "touch: thiếu file" }
            let full = resolve(path)
            _ = DirectEngine.shared.ensureFileAccess(full)
            if fileManager.fileExists(atPath: full) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: full)
                return "Đã chạm \(full)"
            }
            return fileManager.createFile(atPath: full, contents: Data()) ? "Đã tạo \(full)" : "touch: không tạo được"
        case "rm":
            let recursive = args.contains("-r") || args.contains("-rf")
            guard let path = args.last(where: { !$0.hasPrefix("-") }) else { return "rm: thiếu path" }
            let full = resolve(path)
            guard full != "/", full != NSHomeDirectory() else { return "rm: từ chối xoá gốc" }
            _ = DirectEngine.shared.ensureFileAccess(full)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory) else { return "rm: không thấy \(full)" }
            if isDirectory.boolValue && !recursive {
                return "rm: \(full) là thư mục (dùng -r)"
            }
            do {
                try fileManager.removeItem(atPath: full)
                return "Đã xoá \(full)"
            } catch {
                return "rm: \(error.localizedDescription)"
            }
        case "cp", "mv":
            guard args.count >= 2 else { return "\(command): thiếu đích" }
            let source = resolve(args[0])
            let destination = resolve(args[1])
            _ = DirectEngine.shared.ensureFileAccess(source)
            _ = DirectEngine.shared.ensureFileAccess(destination)
            do {
                if command == "mv" {
                    try fileManager.moveItem(atPath: source, toPath: destination)
                } else {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
                return "Đã \(command == "mv" ? "chuyển" : "sao chép") \(source) → \(destination)"
            } catch {
                return "\(command): \(error.localizedDescription)"
            }
        case "df":
            let full = resolve(args.first ?? "/")
            guard let attributes = try? fileManager.attributesOfFileSystem(forPath: full),
                  let free = attributes[.systemFreeSize] as? NSNumber,
                  let total = attributes[.systemSize] as? NSNumber else {
                return "df: không đọc được"
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "\(full)\nTrống: \(formatter.string(fromByteCount: free.int64Value)) / Tổng: \(formatter.string(fromByteCount: total.int64Value))"
        case "echo":
            return args.joined(separator: " ")
        case "whoami":
            return "mobile"
        case "date":
            return Date().formatted(date: .abbreviated, time: .standard)
        case "clear":
            return "\u{000C}"
        default:
            return "\(command): không có lệnh này (gõ help)"
        }
    }

    // MARK: - Helpers

    private func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        return (full as NSString).standardizingPath
    }

    private func changeDirectory(_ path: String?) -> String {
        let full = resolve(path ?? NSHomeDirectory())
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "cd: không phải thư mục: \(full)"
        }
        cwd = full
        return cwd
    }

    private func list(_ path: String?) -> String {
        let full = resolve(path ?? cwd)
        _ = DirectEngine.shared.ensureFileAccess(full)
        guard let entries = try? fileManager.contentsOfDirectory(
            atPath: full
        ) else {
            let fallback = DirectEngine.shared.listDirectorySafe(full)
            guard !fallback.isEmpty else { return "ls: không đọc được \(full)" }
            return fallback.sorted().map { "  \($0)" }.joined(separator: "\n")
        }
        var lines: [String] = []
        for entry in entries.sorted() {
            let child = (full as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: child, isDirectory: &isDirectory)
            let size = (try? fileManager.attributesOfItem(atPath: child)[.size] as? NSNumber) ?? nil
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let detail = isDirectory.boolValue ? "dir" : formatter.string(fromByteCount: size?.int64Value ?? 0)
            lines.append("  \(isDirectory.boolValue ? "d" : "-") \(entry)  [\(detail)]")
        }
        return lines.isEmpty ? "(trống)" : lines.joined(separator: "\n")
    }

    private func readFile(_ path: String, lines limit: Int?) -> String {
        let full = resolve(path)
        _ = DirectEngine.shared.ensureFileAccess(full)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: full), options: .mappedIfSafe) else {
            return "không đọc được \(full)"
        }
        let clipped = data.prefix(64 * 1024)
        guard var text = String(data: clipped, encoding: .utf8) else {
            return "(nhị phân, \(data.count) bytes — dùng viewer hex)"
        }
        if let limit {
            text = text.split(separator: "\n").prefix(limit).joined(separator: "\n")
        }
        return text
    }
}

/// Màn console kiểu terminal.
struct ShellConsoleView: View {
    @State private var lines: [String] = ["bbbbbb shell — gõ `help` để bắt đầu"]
    @State private var input = ""
    @State private var shell = MiniShell()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: lines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(Color.black)
            .foregroundStyle(Color.green)

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.green)
                TextField(L.t("Nhập lệnh…", "Type a command…"), text: $input)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onSubmit(runCommand)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Shell")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
    }

    private func runCommand() {
        let command = input
        input = ""
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lines.append("$ \(command)")
        let output = shell.run(command)
        if output == "\u{000C}" {
            lines = []
            return
        }
        if !output.isEmpty {
            lines.append(contentsOf: output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
    }
}
