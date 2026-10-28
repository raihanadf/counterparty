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
        guard let host = url.host else { throw SocketError(errorDescription: "no host in \(url)") }
        var direct = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        direct.host = try await resolve(host)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 * 1024 * 1024
        websocket.setAdditionalHeaders([("Host", host)])
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let connection = NWConnection(to: .url(direct.url!), using: parameters)
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
        return WebSocket(connection)
    }

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
