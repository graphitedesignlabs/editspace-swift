#if canImport(Network)
import Foundation
import Network

public enum NetworkV1NodeEvent: Sendable {
    case ready(port: UInt16)
    case discovered(NetworkPeerID)
    case connected(NetworkPeerID)
    case synchronized(NetworkPeerID)
    case disconnected(NetworkPeerID?, String?)
    case received(EditOperation, from: NetworkPeerID)
    case error(NetworkV1ErrorMessage, from: NetworkPeerID?)
}

public enum NetworkV1NodeError: Error, Sendable {
    case alreadyRunning
    case listenerFailed(String)
}

/// A complete Apple Network-framework binding for the EditSpace v1 LAN protocol.
public final class NetworkV1Node: @unchecked Sendable {
    public static let serviceType = "_editspace._tcp"
    public static let serviceDomain = "local."

    public let peerID: NetworkPeerID
    public let repository: NetworkV1Repository

    private let selectedSpaces: Set<SpaceID>
    private let eventHandler: @Sendable (NetworkV1NodeEvent) -> Void
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [ObjectIdentifier: NetworkV1Link] = [:]
    private var peerLinks: [NetworkPeerID: NetworkV1Link] = [:]
    private var connectingPeers: Set<NetworkPeerID> = []
    private var candidateEndpoints: [NetworkPeerID: NWEndpoint] = [:]
    private var retryAttempts: [NetworkPeerID: Int] = [:]
    private var retryItems: [NetworkPeerID: DispatchWorkItem] = [:]

    public init(
        peerID: NetworkPeerID,
        repository: NetworkV1Repository,
        selectedSpaces: Set<SpaceID>,
        eventHandler: @escaping @Sendable (NetworkV1NodeEvent) -> Void = { _ in }
    ) {
        self.peerID = peerID
        self.repository = repository
        self.selectedSpaces = selectedSpaces
        self.eventHandler = eventHandler
        queue = DispatchQueue(label: "org.editspace.network.v1.\(peerID.rawValue)")
    }

    public func start() throws {
        guard listener == nil, browser == nil else { throw NetworkV1NodeError.alreadyRunning }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            throw NetworkV1NodeError.listenerFailed(error.localizedDescription)
        }
        listener.service = NWListener.Service(
            name: "EditSpace-\(peerID.rawValue.prefix(8))",
            type: Self.serviceType,
            domain: Self.serviceDomain,
            txtRecord: Self.txtRecord(peerID: peerID)
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port { self.eventHandler(.ready(port: port.rawValue)) }
            case .failed(let error):
                self.eventHandler(.disconnected(nil, error.localizedDescription))
                self.stop()
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: Self.serviceDomain),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.eventHandler(.disconnected(nil, error.localizedDescription))
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.listener?.cancel()
            self.browser = nil
            self.listener = nil
            self.links.values.forEach { $0.cancel() }
            self.links.removeAll()
            self.peerLinks.removeAll()
            self.connectingPeers.removeAll()
            self.candidateEndpoints.removeAll()
            self.retryItems.values.forEach { $0.cancel() }
            self.retryItems.removeAll()
            self.retryAttempts.removeAll()
        }
    }

    /// Appends a local operation and immediately offers it to every live direct neighbor.
    @discardableResult
    public func publish(_ operation: EditOperation) async -> NetworkV1ImportResult {
        let result = await repository.appendLocal(operation)
        guard result == .appended else { return result }
        queue.async { [weak self] in
            self?.peerLinks.values.forEach { $0.publish(operation) }
        }
        return result
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var seenPeers: Set<NetworkPeerID> = []
        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata,
                  let record = Self.parseTXTRecord(txtRecord.dictionary),
                  record.networkVersions.contains(1), record.operationVersions.contains(1),
                  record.capabilities.contains("tcp"), record.capabilities.contains("history-ranges"),
                  record.peerID != peerID else { continue }
            seenPeers.insert(record.peerID)
            candidateEndpoints[record.peerID] = result.endpoint
            eventHandler(.discovered(record.peerID))
            guard peerID < record.peerID, peerLinks[record.peerID] == nil,
                  !connectingPeers.contains(record.peerID) else { continue }
            connectingPeers.insert(record.peerID)
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            addLink(connection: connection, outbound: true, expectedPeerID: record.peerID)
        }
        for missingPeer in Set(candidateEndpoints.keys).subtracting(seenPeers) {
            candidateEndpoints.removeValue(forKey: missingPeer)
            retryItems.removeValue(forKey: missingPeer)?.cancel()
            retryAttempts.removeValue(forKey: missingPeer)
        }
    }

    private func accept(_ connection: NWConnection) {
        addLink(connection: connection, outbound: false, expectedPeerID: nil)
    }

    private func addLink(connection: NWConnection, outbound: Bool, expectedPeerID: NetworkPeerID?) {
        let session = NetworkV1Session(
            localPeerID: peerID,
            expectedRemotePeerID: expectedPeerID,
            repository: repository,
            selectedSpaces: selectedSpaces
        )
        let link = NetworkV1Link(connection: connection, session: session, outbound: outbound, queue: queue)
        let identifier = ObjectIdentifier(link)
        links[identifier] = link
        link.onIdentified = { [weak self, weak link] remotePeerID in
            guard let self, let link else { return false }
            let correctDirection = outbound ? self.peerID < remotePeerID : self.peerID > remotePeerID
            guard correctDirection else { return false }
            if let existing = self.peerLinks[remotePeerID] {
                let candidate = NetworkV1ConnectionCandidate(
                    initiatorPeerID: min(self.peerID, remotePeerID),
                    initiatorPort: link.initiatorPort
                )
                let incumbent = NetworkV1ConnectionCandidate(
                    initiatorPeerID: min(self.peerID, remotePeerID),
                    initiatorPort: existing.initiatorPort
                )
                guard NetworkV1ConnectionSelection.preferred(between: candidate, and: incumbent) == candidate else {
                    return false
                }
                existing.cancel()
            }
            self.peerLinks[remotePeerID] = link
            self.connectingPeers.remove(remotePeerID)
            self.retryItems.removeValue(forKey: remotePeerID)?.cancel()
            self.retryAttempts.removeValue(forKey: remotePeerID)
            self.eventHandler(.connected(remotePeerID))
            return true
        }
        link.onEvent = { [weak self] event in self?.eventHandler(event) }
        link.onClosed = { [weak self, weak link] remotePeerID, error in
            guard let self else { return }
            self.links.removeValue(forKey: identifier)
            if let remotePeerID, self.peerLinks[remotePeerID] === link {
                self.peerLinks.removeValue(forKey: remotePeerID)
            }
            let retryPeerID = remotePeerID ?? expectedPeerID
            if let retryPeerID {
                self.connectingPeers.remove(retryPeerID)
                self.scheduleRetry(for: retryPeerID)
            }
            self.eventHandler(.disconnected(remotePeerID, error))
        }
        link.start()
    }

    private func scheduleRetry(for remotePeerID: NetworkPeerID) {
        guard peerID < remotePeerID, peerLinks[remotePeerID] == nil,
              candidateEndpoints[remotePeerID] != nil, retryItems[remotePeerID] == nil else { return }
        let attempt = retryAttempts[remotePeerID, default: 0]
        retryAttempts[remotePeerID] = attempt + 1
        let ceiling = min(30.0, pow(2.0, Double(attempt)))
        let delay = Double.random(in: max(0.25, ceiling / 2)...ceiling)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryItems.removeValue(forKey: remotePeerID)
            guard let endpoint = self.candidateEndpoints[remotePeerID],
                  self.peerLinks[remotePeerID] == nil,
                  !self.connectingPeers.contains(remotePeerID) else { return }
            self.connectingPeers.insert(remotePeerID)
            self.addLink(
                connection: NWConnection(to: endpoint, using: .tcp),
                outbound: true,
                expectedPeerID: remotePeerID
            )
        }
        retryItems[remotePeerID] = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private struct DiscoveryRecord {
        let peerID: NetworkPeerID
        let networkVersions: [Int]
        let operationVersions: [Int]
        let capabilities: Set<String>
    }

    private static func txtRecord(peerID: NetworkPeerID) -> Data {
        encodeTXT([
            "net": "1",
            "ops": "1",
            "peer": peerID.rawValue,
            "caps": "history-ranges,tcp"
        ])
    }

    private static func parseTXTRecord(_ values: [String: String]) -> DiscoveryRecord? {
        guard values.count >= 4,
              let peerValue = values["peer"],
              let netValue = values["net"],
              let opsValue = values["ops"],
              let capsValue = values["caps"] else { return nil }
        let peerID = NetworkPeerID(rawValue: peerValue)
        guard peerID.isCanonical else { return nil }
        let networkVersions = parseVersions(netValue)
        let operationVersions = parseVersions(opsValue)
        let capabilities = capsValue.split(separator: ",").map(String.init)
        guard !networkVersions.isEmpty, !operationVersions.isEmpty,
              capabilities == capabilities.sorted(), Set(capabilities).count == capabilities.count else { return nil }
        return DiscoveryRecord(
            peerID: peerID,
            networkVersions: networkVersions,
            operationVersions: operationVersions,
            capabilities: Set(capabilities)
        )
    }

    private static func parseVersions(_ value: String) -> [Int] {
        let strings = value.split(separator: ",", omittingEmptySubsequences: false)
        let versions = strings.compactMap { part -> Int? in
            guard !part.isEmpty, part == "0" || part.first != "0", let version = Int(part), version > 0 else { return nil }
            return version
        }
        guard versions.count == strings.count, versions == Array(Set(versions)).sorted(by: >) else { return [] }
        return versions
    }

    private static func encodeTXT(_ values: [String: String]) -> Data {
        var data = Data()
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { continue }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

}

private final class NetworkV1Link: @unchecked Sendable {
    let connection: NWConnection
    let session: NetworkV1Session
    let outbound: Bool
    let queue: DispatchQueue
    var onIdentified: ((NetworkPeerID) -> Bool)?
    var onEvent: ((NetworkV1NodeEvent) -> Void)?
    var onClosed: ((NetworkPeerID?, String?) -> Void)?

    private var frameCodec = NetworkV1FrameCodec()
    private var remotePeerID: NetworkPeerID?
    private var didClose = false
    private var timeoutItem: DispatchWorkItem?

    var initiatorPort: UInt16 {
        guard let path = connection.currentPath else { return UInt16.max }
        let endpoint = outbound ? path.localEndpoint : path.remoteEndpoint
        guard case .hostPort(_, let port) = endpoint else { return UInt16.max }
        return port.rawValue
    }

    init(connection: NWConnection, session: NetworkV1Session, outbound: Bool, queue: DispatchQueue) {
        self.connection = connection
        self.session = session
        self.outbound = outbound
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.armTimeout(seconds: 30)
                Task {
                    await self.send(await self.session.initialMessages())
                    self.receive()
                }
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func publish(_ operation: EditOperation) {
        Task {
            guard let message = await session.liveBatch(for: operation) else { return }
            await send([message])
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.armTimeout(seconds: 120)
                do {
                    for payload in try self.frameCodec.append(data) {
                        let message = try NetworkV1MessageCodec.decode(payload)
                        Task { await self.process(message) }
                    }
                } catch {
                    Task { await self.send([.error(NetworkV1ErrorMessage(code: .invalidFrame, message: error.localizedDescription))]) }
                    self.close(error.localizedDescription)
                    return
                }
            }
            if let error { self.close(error.localizedDescription) }
            else if complete { self.close(nil) }
            else { self.receive() }
        }
    }

    private func process(_ message: NetworkV1Message) async {
        if case .hello(let hello) = message, remotePeerID == nil {
            guard onIdentified?(hello.peerID) == true else {
                await send([.error(NetworkV1ErrorMessage(code: .peerIDMismatch, message: "Duplicate or incorrectly directed connection"))])
                close("Duplicate or incorrectly directed connection")
                return
            }
            remotePeerID = hello.peerID
        }
        if case .operationBatch(let batch) = message, let remotePeerID {
            for envelope in batch.envelopes {
                for operation in envelope.operations { onEvent?(.received(operation, from: remotePeerID)) }
            }
        }
        do {
            let responses = try await session.receive(message)
            await send(responses)
            let state = await session.state
            switch state {
            case .hello, .selection: armTimeout(seconds: 30)
            case .synchronizing: armTimeout(seconds: 120)
            case .live:
                cancelTimeout()
                if let remotePeerID { onEvent?(.synchronized(remotePeerID)) }
            case .closed: cancelTimeout()
            }
        } catch NetworkV1SessionError.protocolError(let error) {
            onEvent?(.error(error, from: remotePeerID))
            if error.fatal { close(error.message) }
        } catch {
            close(error.localizedDescription)
        }
    }

    private func send(_ messages: [NetworkV1Message]) async {
        for message in messages {
            do {
                let data = try NetworkV1FrameCodec.encode(message: message)
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error { self?.close(error.localizedDescription) }
                })
            } catch {
                close(error.localizedDescription)
                return
            }
        }
    }

    private func close(_ error: String?) {
        guard !didClose else { return }
        didClose = true
        timeoutItem?.cancel()
        timeoutItem = nil
        connection.cancel()
        onClosed?(remotePeerID, error)
    }

    private func armTimeout(seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.didClose else { return }
            self.timeoutItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.close("Protocol timeout") }
            self.timeoutItem = item
            self.queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    private func cancelTimeout() {
        queue.async { [weak self] in
            self?.timeoutItem?.cancel()
            self?.timeoutItem = nil
        }
    }
}
#endif
