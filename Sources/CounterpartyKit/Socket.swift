import Foundation
import Network

// some isps (indonesia's internetpositif) hijack exchange domains through dns, so the system resolver
// hands out a block page instead of the exchange. sockets resolve through cloudflare's dns-over-https
// instead and connect to that address, with tls and the http host still set to the real name.

struct SocketError: LocalizedError {
    let errorDescription: String?
}

private struct DNSReply: Decodable {
    struct Answer: Decodable {
        let type: Int
        let data: String
    }
    let Answer: [Answer]?
}

private func resolve(_ host: String) async throws -> String {
    var request = URLRequest(url: URL(string: "https://1.1.1.1/dns-query?name=\(host)&type=A")!)
    request.setValue("application/dns-json", forHTTPHeaderField: "accept")
    let (data, _) = try await URLSession.shared.data(for: request)
    // type 1 is an ipv4 address, the other answers are cname hops
    guard let address = try JSONDecoder().decode(DNSReply.self, from: data).Answer?.first(where: { $0.type == 1 })?.data else {
        throw SocketError(errorDescription: "no address for \(host)")
    }
    return address
}

final class WebSocket: Sendable {
    private let connection: NWConnection

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    static func connect(_ url: URL) async throws -> WebSocket {
        let (address, parameters) = try await route(url)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 * 1024 * 1024
        websocket.setAdditionalHeaders([("Host", url.host!)])
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let connection = NWConnection(to: .url(address), using: parameters)
        try await open(connection)
        return WebSocket(connection)
    }
}

// the url with its host swapped for the address cloudflare resolves, and tls set up for the real name
private func route(_ url: URL) async throws -> (URL, NWParameters) {
    guard let host = url.host else { throw SocketError(errorDescription: "no host in \(url)") }
    var direct = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    direct.host = try await resolve(host)
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
    return (direct.url!, NWParameters(tls: tls))
}

private func open(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                continuation.resume()
            case .waiting(let error), .failed(let error):
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

// a plain https get for endpoints the system resolver can't reach and aggr's proxy doesn't carry
// (bybit pages its product list, the proxy only knows the first page)
func httpGet(_ url: URL) async throws -> Data {
    let (address, parameters) = try await route(url)
    let connection = NWConnection(host: NWEndpoint.Host(address.host!), port: 443, using: parameters)
    try await open(connection)
    defer { connection.cancel() }

    let path = url.path + (url.query.map { "?" + $0 } ?? "")
    let request = "GET \(path) HTTP/1.1\r\nHost: \(url.host!)\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }

    // connection: close, so the response ends when the server hangs up
    var response = Data()
    while true {
        let (chunk, done) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
            }
        }
        if let chunk { response.append(chunk) }
        if done { break }
    }

    guard let split = response.firstRange(of: Data("\r\n\r\n".utf8)) else { throw SocketError(errorDescription: "\(url.host!) sent no http headers") }
    let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
    var body = Data(response[split.upperBound...])
    guard head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else {
        throw SocketError(errorDescription: "\(url.host!) answered \(head.split(separator: "\r\n").first ?? "")")
    }
    if head.lowercased().contains("transfer-encoding: chunked") {
        body = try unchunk(body)
    }
    return body
}

// chunked transfer encoding: hex size line, that many bytes, crlf, until a zero size
private func unchunk(_ data: Data) throws -> Data {
    var output = Data()
    var index = data.startIndex
    let crlf = Data("\r\n".utf8)
    while let line = data[index...].firstRange(of: crlf) {
        let sizeText = String(decoding: data[index..<line.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
            throw SocketError(errorDescription: "bad chunk size \"\(sizeText)\"")
        }
        if size == 0 { return output }
        let start = line.upperBound
        guard data.distance(from: start, to: data.endIndex) >= size + 2 else { throw SocketError(errorDescription: "response ended mid chunk") }
        let end = data.index(start, offsetBy: size)
        output.append(data[start..<end])
        index = data.index(end, offsetBy: 2)
    }
    throw SocketError(errorDescription: "response ended without its last chunk")
}

extension WebSocket {

    func send(_ text: String) async throws {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), contentContext: context, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    // next text or binary message, throws when the socket closes
    func receive() async throws -> Data {
        while true {
            let (data, opcode) = try await frame()
            switch opcode {
            case .close:
                throw SocketError(errorDescription: "closed by the exchange")
            // pings are answered by the protocol (autoReplyPing), they still surface here without a payload
            case .ping, .pong:
                continue
            default:
                guard let data else { throw SocketError(errorDescription: "connection ended (\(opcode.map { "\($0)" } ?? "no frame"))") }
                return data
            }
        }
    }

    private func frame() async throws -> (Data?, NWProtocolWebSocket.Opcode?) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, metadata?.opcode))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
