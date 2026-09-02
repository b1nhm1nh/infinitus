import Foundation
import Network
import InfinitusCore

/// The latest encoded snapshot, shared between the exporter actor (which
/// writes it) and the NWConnection handlers on the network queue (which
/// read it). A lock, not an actor: the connection callbacks are
/// synchronous and must answer without hopping executors.
final class MirrorPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    var latest: Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func set(_ new: Data) {
        lock.lock(); data = new; lock.unlock()
    }
}

/// Serves the fleet snapshot to the phone over the LAN (#9): one Bonjour
/// advertised (`_infinitus._tcp`) TCP listener answering `GET /snapshot`
/// with the exact bytes MirrorExporter wrote. Off by default behind the
/// Sync pane's toggle; no auth beyond "you're on this network", which is
/// what the toggle's help text says.
@MainActor
final class MirrorServer: ObservableObject {
    /// The bound port, once the listener is ready.
    @Published private(set) var port: UInt16?
    /// One line for the Settings pane.
    @Published private(set) var status: String?

    /// Handed to MirrorExporter so every export lands here too.
    let payload = MirrorPayloadBox()
    /// Event-log sink (icon, text), set by AppModel.
    var log: ((String, String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.huuloc.limitless.mirror-server")

    func start(machineName: String) {
        guard listener == nil else { return }
        // The last export renders immediately: a phone that asks before
        // the first refresh of this launch still gets a fleet.
        if payload.latest == nil,
           let data = try? Data(contentsOf: MirrorExporter.url) {
            payload.set(data)
        }
        status = "starting…"
        listen(on: MirrorTransport.defaultPort, name: machineName)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = nil
    }

    private func listen(on rawPort: UInt16, name: String) {
        let params = NWParameters.tcp
        // Toggling the server off and on shouldn't trip over TIME_WAIT.
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        let endpointPort = rawPort == 0 ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: rawPort) ?? .any
        guard let listener = try? NWListener(using: params, on: endpointPort) else {
            status = "couldn't open a port"
            return
        }
        listener.service = NWListener.Service(name: name,
                                              type: MirrorTransport.bonjourType)
        let payload = self.payload
        listener.newConnectionHandler = { [queue] connection in
            Self.serve(connection, payload: payload, queue: queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, wasFixedPort: rawPort != 0, name: name) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func handle(_ state: NWListener.State, wasFixedPort: Bool, name: String) {
        switch state {
        case .ready:
            let bound = listener?.port?.rawValue
            port = bound
            status = "serving \(name) on port \(bound.map(String.init) ?? "?")"
            log?("📱", "phone companion listening on port \(bound.map(String.init) ?? "?")")
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The fixed port is only a convenience for the phone's manual
            // override — if something else holds it, take any port and
            // let Bonjour carry the number.
            if wasFixedPort, case .posix(.EADDRINUSE) = error {
                listen(on: 0, name: name)
            } else {
                port = nil
                status = "failed: \(error.localizedDescription)"
                log?("⚠️", "phone companion failed: \(error.localizedDescription)")
            }
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    // MARK: - Connection handling (network queue)

    private nonisolated static func serve(_ connection: NWConnection,
                                          payload: MirrorPayloadBox,
                                          queue: DispatchQueue) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), payload: payload)
    }

    private nonisolated static func receive(_ connection: NWConnection,
                                            buffer: Data,
                                            payload: MirrorPayloadBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let target = MirrorTransport.requestTarget(buffer) {
                let response: Data
                if target.method == "GET", target.path == MirrorTransport.snapshotPath {
                    response = payload.latest.map(MirrorTransport.snapshotResponse)
                        ?? MirrorTransport.unavailableResponse()
                } else {
                    response = MirrorTransport.notFoundResponse()
                }
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // Nothing to answer yet — and nothing ever will be if the peer
            // hung up or is spraying bytes without a request line.
            guard error == nil, !isComplete, buffer.count < 8192 else {
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer, payload: payload)
        }
    }
}
