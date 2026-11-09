import Combine
import Foundation
import Network

struct LocalShowcaseCamera: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

struct LocalShowcaseQuestion: Decodable, Sendable {
    let cameraID: UUID
    let question: String
}

struct LocalShowcaseRequest: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    static let maximumRequestBytes = 16 * 1024
    static let maximumQuestionBytes = 2 * 1024

    static func parse(_ data: Data) -> LocalShowcaseRequest? {
        guard data.count <= maximumRequestBytes,
              let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
            guard headers["transfer-encoding"] == nil else { return nil }
        let body = Data(data[separator.upperBound...])
        let contentLength = Int(headers["content-length"] ?? "0")
        guard let contentLength, contentLength >= 0,
              contentLength <= maximumQuestionBytes,
              body.count == contentLength else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        return LocalShowcaseRequest(
            method: String(parts[0]), path: components.path,
            query: query, headers: headers, body: body
        )
    }

    static func authorizes(_ request: LocalShowcaseRequest, token: String) -> Bool {
        guard let value = request.headers["authorization"], value.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(value.dropFirst("Bearer ".count)), token)
    }

    static func matchesPageToken(_ candidate: String, token: String) -> Bool {
        constantTimeEqual(candidate, token)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

@MainActor
final class LocalShowcaseServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var shareURL: URL?
    @Published private(set) var status = "Stopped"

    typealias CameraProvider = @MainActor () -> [LocalShowcaseCamera]
    typealias SnapshotProvider = @MainActor (UUID) async throws -> Data
    typealias QuestionHandler = @MainActor (UUID, String) async throws -> String
    typealias StatusHandler = @MainActor (URL?, String, Bool) -> Void

    private let cameraProvider: CameraProvider
    private let snapshotProvider: SnapshotProvider
    private let questionHandler: QuestionHandler
    private let statusHandler: StatusHandler
    private let maximumConnections = 8
    private let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(cameraProvider: @escaping CameraProvider,
         snapshotProvider: @escaping SnapshotProvider,
         questionHandler: @escaping QuestionHandler,
         statusHandler: @escaping StatusHandler) {
        self.cameraProvider = cameraProvider
        self.snapshotProvider = snapshotProvider
        self.questionHandler = questionHandler
        self.statusHandler = statusHandler
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue,
                          let url = URL(string: "http://127.0.0.1:\(port)/?token=\(self.token)") else {
                        self.status = "Could not create the local share URL"
                        return
                    }
                    self.shareURL = url
                    self.isRunning = true
                    self.status = "Serving on this Mac only"
                    self.statusHandler(url, self.status, true)
                case .failed:
                    self.stop()
                    self.status = "Local showcase failed to start"
                    self.statusHandler(nil, self.status, false)
                case .cancelled:
                    self.isRunning = false
                    self.shareURL = nil
                    self.status = "Stopped"
                    self.statusHandler(nil, self.status, false)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
        status = "Starting local showcase"
        statusHandler(nil, status, false)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        isRunning = false
        shareURL = nil
        status = "Stopped"
        statusHandler(nil, status, false)
    }

    private func accept(_ connection: NWConnection) {
        guard activeConnections.count < maximumConnections else {
            connection.start(queue: .main)
            send(connection, status: 503, contentType: "text/plain", body: Data("Busy".utf8))
            return
        }
        activeConnections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var combined = buffered
                if let data { combined.append(data) }
                if combined.count > LocalShowcaseRequest.maximumRequestBytes {
                    self.send(connection, status: 413, contentType: "text/plain", body: Data("Request too large".utf8))
                    return
                }
                if let request = LocalShowcaseRequest.parse(combined) {
                    await self.route(request, connection: connection)
                } else if complete || error != nil {
                    self.send(connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8))
                } else {
                    self.receive(connection, buffered: combined)
                }
            }
        }
    }

    private func route(_ request: LocalShowcaseRequest, connection: NWConnection) async {
          if request.method == "GET", request.path == "/",
              LocalShowcaseRequest.matchesPageToken(request.query["token"] ?? "", token: token) {
            send(connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(Self.page.utf8))
            return
        }
        guard authorized(request) else {
            send(connection, status: 401, contentType: "text/plain", body: Data("Unauthorized".utf8))
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/api/cameras"):
            let encoder = JSONEncoder()
            let body = (try? encoder.encode(cameraProvider())) ?? Data("[]".utf8)
            send(connection, status: 200, contentType: "application/json", body: body)
        case ("GET", "/api/snapshot"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)),
                  cameraProvider().contains(where: { $0.id == id }) else {
                send(connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8))
                return
            }
            do {
                let image = try await snapshotProvider(id)
                send(connection, status: 200, contentType: "image/jpeg", body: image)
            } catch {
                send(connection, status: 503, contentType: "text/plain", body: Data("No fresh frame".utf8))
            }
        case ("POST", "/api/ask"):
            guard let question = try? JSONDecoder().decode(LocalShowcaseQuestion.self, from: request.body),
                  question.question.trimmingCharacters(in: .whitespacesAndNewlines).count > 0,
                  question.question.count <= 1000,
                  cameraProvider().contains(where: { $0.id == question.cameraID }) else {
                send(connection, status: 400, contentType: "text/plain", body: Data("Invalid question".utf8))
                return
            }
            do {
                let answer = try await questionHandler(
                    question.cameraID,
                    String(question.question.prefix(1000))
                )
                let payload = try JSONSerialization.data(withJSONObject: ["answer": String(answer.prefix(2000))])
                send(connection, status: 200, contentType: "application/json", body: payload)
            } catch {
                send(connection, status: 503, contentType: "text/plain", body: Data("Local analysis unavailable".utf8))
            }
        default:
            send(connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func authorized(_ request: LocalShowcaseRequest) -> Bool {
        LocalShowcaseRequest.authorizes(request, token: token)
    }

    private func send(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : (status == 503 ? "Service Unavailable" : "Bad Request")))
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(connection) }
        })
    }

    private func finish(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private static let page = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Local CameraWall</title>
    <style>body{font:16px -apple-system,sans-serif;max-width:980px;margin:24px auto;padding:0 16px;color:#17212b}select,input,button{font:inherit;padding:8px}img{display:block;width:100%;max-height:70vh;object-fit:contain;background:#111}form{display:flex;gap:8px;margin-top:12px}input{flex:1}</style>
    <h1>Local CameraWall</h1><label>Camera <select id="camera"></select></label><img id="frame" alt="Live camera frame"><form id="ask"><input id="question" maxlength="1000" aria-label="Question about this frame" placeholder="Ask about the visible scene"><button>Ask locally</button></form><p id="answer" aria-live="polite"></p>
    <script>const token=new URL(location.href).searchParams.get('token')||'';history.replaceState(null,'','/');const headers={Authorization:'Bearer '+token};const cameras=document.getElementById('camera'),frame=document.getElementById('frame');async function load(){const list=await fetch('/api/cameras',{headers}).then(r=>r.json());cameras.replaceChildren(...list.map(c=>{const o=document.createElement('option');o.value=c.id;o.textContent=c.name;return o}));refresh()}async function refresh(){try{if(!cameras.value)return;const r=await fetch('/api/snapshot?id='+encodeURIComponent(cameras.value),{headers});if(r.ok){const old=frame.src;frame.src=URL.createObjectURL(await r.blob());if(old.startsWith('blob:'))URL.revokeObjectURL(old)}}catch{}finally{setTimeout(refresh,1500)}}document.getElementById('ask').onsubmit=async e=>{e.preventDefault();const r=await fetch('/api/ask',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({cameraID:cameras.value,question:document.getElementById('question').value})});document.getElementById('answer').textContent=r.ok?(await r.json()).answer:'Local analysis unavailable'};load();</script></html>
    """
}