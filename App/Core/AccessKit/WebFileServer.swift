import Combine
import Foundation
import Network

/// HTTP file server trong app (kiểu WebDAV-lite, như Filza 27.2): duyệt và
/// tải file qua LAN — chỉ chạy khi app mở.
///
/// - Cổng 11111 (fallback cổng trống), Bonjour `bbbbbb` → http://bbbbbb.local:11111
/// - Basic Auth: `mobile` / `bbbbbb`
/// - Gốc duyệt: container dữ liệu của app (mọi đường dẫn đều qua
///   `ensureFileAccess` nên file trong container khác đọc được nếu có token).
final class WebFileServer: ObservableObject {
    static let shared = WebFileServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 11111
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.d3vin4.bbbbbb.webfile")
    private let user = "mobile"
    private let password = "bbbbbb"
    private var root: String { NSHomeDirectory() }

    func start(preferredPort: UInt16 = 11111) {
        guard listener == nil else { return }
        do {
            let nwPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(name: "bbbbbb", type: "_http._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let assigned = listener.port?.rawValue ?? preferredPort
                    DispatchQueue.main.async {
                        self.port = assigned
                        self.isRunning = true
                        self.lastError = nil
                    }
                    Log.info(
                        "WebFile: sẵn sàng — http://bbbbbb.local:\(assigned) (\(self.user)/\(self.password))",
                        category: .app
                    )
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                    }
                    Log.warning("WebFile: lỗi \(error.localizedDescription)", category: .app)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            Log.warning("WebFile: không mở được cổng \(preferredPort): \(error.localizedDescription)", category: .app)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
        Log.info("WebFile: đã dừng", category: .app)
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(connection, status: "400 Bad Request", body: Data("Yêu cầu không hợp lệ".utf8))
                return
            }
            let method = String(parts[0])
            let path = String(parts[1])
            guard self.isAuthorized(request) else {
                self.respond(
                    connection,
                    status: "401 Unauthorized",
                    body: Data("Cần đăng nhập: \(self.user)/\(self.password)".utf8),
                    extraHeaders: ["WWW-Authenticate": "Basic realm=\"bbbbbb\""]
                )
                return
            }
            switch method {
            case "GET", "HEAD":
                self.serve(path: path, method: method, on: connection)
            case "PUT":
                self.receiveBody(request: request, chunk: data, connection: connection, path: path)
            case "DELETE":
                self.delete(path: path, on: connection)
            default:
                self.respond(
                    connection,
                    status: "405 Method Not Allowed",
                    body: Data("Hỗ trợ GET/HEAD/PUT/DELETE".utf8)
                )
            }
        }
    }

    private func isAuthorized(_ request: String) -> Bool {
        for line in request.split(separator: "\r\n") where line.lowercased().hasPrefix("authorization:") {
            let value = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            guard value.lowercased().hasPrefix("basic ") else { continue }
            let encoded = String(value.dropFirst(6))
            guard let decoded = Data(base64Encoded: encoded),
                  let pair = String(data: decoded, encoding: .utf8) else { continue }
            if pair == "\(user):\(password)" { return true }
        }
        return false
    }

    private func serve(path rawPath: String, method: String, on connection: NWConnection) {
        var relative = rawPath
        if let query = relative.firstIndex(of: "?") {
            relative = String(relative[..<query])
        }
        relative = relative.removingPercentEncoding ?? relative
        let clean = relative
            .split(separator: "/")
            .filter { $0 != ".." && $0 != "." }
            .joined(separator: "/")
        let fullPath = clean.isEmpty ? root : (root as NSString).appendingPathComponent(clean)
        _ = DirectEngine.shared.ensureFileAccess(fullPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
            respond(connection, status: "404 Not Found", body: Data("Không thấy /\(clean)".utf8))
            return
        }

        if isDirectory.boolValue {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: fullPath)) ?? []
            var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>bbbbbb</title></head><body>"
            html += "<h3>bbbbbb — /\(clean)</h3><ul>"
            if !clean.isEmpty {
                html += "<li><a href=\"/\">..</a></li>"
            }
            for entry in entries.sorted() {
                let child = clean.isEmpty ? entry : clean + "/" + entry
                html += "<li><a href=\"/\(child)\">\(entry)</a></li>"
            }
            html += "</ul></body></html>"
            respond(
                connection,
                status: "200 OK",
                body: method == "HEAD" ? Data() : Data(html.utf8),
                contentType: "text/html; charset=utf-8"
            )
            return
        }

        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: fullPath), options: .mappedIfSafe) else {
            respond(connection, status: "403 Forbidden", body: Data("Không đọc được file".utf8))
            return
        }
        respond(
            connection,
            status: "200 OK",
            body: method == "HEAD" ? Data() : fileData,
            contentType: "application/octet-stream"
        )
    }

    // MARK: - Ghi / xoá (điều khiển file qua LAN)

    private static func contentLength(in request: String) -> Int {
        for line in request.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    /// Gom đủ body theo Content-Length rồi ghi file (PUT).
    private func receiveBody(
        request: String,
        chunk: Data,
        connection: NWConnection,
        path: String,
        accumulated: Data = Data()
    ) {
        var buffer = accumulated
        buffer.append(chunk)

        let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? buffer.count
        let expected = Self.contentLength(in: request)
        let received = buffer.count > headerEnd ? buffer.count - headerEnd : 0

        guard received >= expected else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, _ in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.receiveBody(
                    request: request,
                    chunk: data ?? Data(),
                    connection: connection,
                    path: path,
                    accumulated: buffer
                )
            }
            return
        }

        let body = received > 0 ? buffer.subdata(in: headerEnd..<(headerEnd + expected)) : Data()
        guard let fullPath = safePath(path) else {
            respond(connection, status: "400 Bad Request", body: Data("Đường dẫn không hợp lệ".utf8))
            return
        }
        _ = DirectEngine.shared.ensureFileAccess(fullPath)
        let directory = (fullPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        do {
            try body.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
            Log.info("WebFile: PUT \(path) (\(body.count) bytes)", category: .app)
            respond(connection, status: "201 Created", body: Data("Đã ghi \(body.count) bytes → /\(path)".utf8))
        } catch {
            respond(connection, status: "500 Internal Server Error", body: Data(error.localizedDescription.utf8))
        }
    }

    private func delete(path rawPath: String, on connection: NWConnection) {
        guard let fullPath = safePath(rawPath) else {
            respond(connection, status: "400 Bad Request", body: Data("Đường dẫn không hợp lệ".utf8))
            return
        }
        _ = DirectEngine.shared.ensureFileAccess(fullPath)
        do {
            try FileManager.default.removeItem(atPath: fullPath)
            Log.info("WebFile: DELETE \(rawPath)", category: .app)
            respond(connection, status: "200 OK", body: Data("Đã xoá /\(rawPath)".utf8))
        } catch {
            respond(connection, status: "500 Internal Server Error", body: Data(error.localizedDescription.utf8))
        }
    }

    private func safePath(_ rawPath: String) -> String? {
        var relative = rawPath
        if let query = relative.firstIndex(of: "?") {
            relative = String(relative[..<query])
        }
        relative = relative.removingPercentEncoding ?? relative
        let clean = relative
            .split(separator: "/")
            .filter { $0 != ".." && $0 != "." }
            .joined(separator: "/")
        guard !clean.isEmpty else { return nil }
        return (root as NSString).appendingPathComponent(clean)
    }

    private func respond(
        _ connection: NWConnection,
        status: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String: String] = [:]
    ) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        for (key, value) in extraHeaders {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
