#if canImport(Network)
import Foundation
import Network
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum NetworkV1SharingName {
    static var currentDeviceName: String {
#if os(watchOS)
        sanitized(WKInterfaceDevice.current().name)
#elseif canImport(UIKit)
        sanitized(UIDevice.current.name)
#elseif canImport(AppKit)
        sanitized(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
#else
        sanitized(ProcessInfo.processInfo.hostName)
#endif
    }

    static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "EditSpace" : trimmed
        var result = ""
        for character in candidate {
            guard (result + String(character)).utf8.count <= 63 else { break }
            result.append(character)
        }
        return result.isEmpty ? "EditSpace" : result
    }
}

public enum NetworkV1NodeEvent: Sendable {
    case ready(port: UInt16)
    case discovered(NetworkPeerID)
    case connected(NetworkPeerID)
    case synchronized(NetworkPeerID)
    case disconnected(NetworkPeerID?, String?)
    case received(EditOperation, from: NetworkPeerID)
    case receivedPresence(PresenceEnvelope, from: NetworkPeerID)
    case receivedApplicationMessage(NetworkV1ApplicationMessage, from: NetworkPeerID)
    case error(NetworkV1ErrorMessage, from: NetworkPeerID?)
}

public enum NetworkV1NodeError: Error, Sendable {
    case alreadyRunning
    case listenerFailed(String)
}

enum NetworkV1PeerInstanceDecision: Equatable {
    case selected
    case current
    case replaced
    case superseded
}

struct NetworkV1PeerInstanceTracker {
    private(set) var currentInstanceIDs: [NetworkPeerID: String] = [:]
    private var supersededInstanceIDs: [NetworkPeerID: Set<String>] = [:]

    mutating func consider(_ instanceID: String, for peerID: NetworkPeerID) -> NetworkV1PeerInstanceDecision {
        guard let currentInstanceID = currentInstanceIDs[peerID] else {
            currentInstanceIDs[peerID] = instanceID
            return .selected
        }
        guard currentInstanceID != instanceID else { return .current }
        guard supersededInstanceIDs[peerID]?.contains(instanceID) != true else { return .superseded }

        supersededInstanceIDs[peerID, default: []].insert(currentInstanceID)
        currentInstanceIDs[peerID] = instanceID
        return .replaced
    }

    mutating func removeAll() {
        currentInstanceIDs.removeAll()
        supersededInstanceIDs.removeAll()
    }
}

/// A complete Apple Network-framework binding for the EditSpace v1 LAN protocol.
public final class NetworkV1Node: @unchecked Sendable {
    public static let serviceType = "_editspace._tcp"
    public static let serviceDomain = "local."

    public let peerID: NetworkPeerID
    public let repository: NetworkV1Repository
    public let sharingName: String

    private var selectedSpaces: Set<SpaceID>
    private let eventHandler: @Sendable (NetworkV1NodeEvent) -> Void
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [ObjectIdentifier: NetworkV1Link] = [:]
    private var peerLinks: [NetworkPeerID: NetworkV1Link] = [:]
    private var connectingPeers: Set<NetworkPeerID> = []
    private var candidateEndpoints: [NetworkPeerID: NWEndpoint] = [:]
    private var candidateInstanceTracker = NetworkV1PeerInstanceTracker()
    private var retryAttempts: [NetworkPeerID: Int] = [:]
    private var retryItems: [NetworkPeerID: DispatchWorkItem] = [:]
    private var pendingApplicationMessages: [NetworkPeerID: [NetworkV1ApplicationMessage]] = [:]
    private var localInstanceID: String?

    public init(
        peerID: NetworkPeerID,
        repository: NetworkV1Repository,
        selectedSpaces: Set<SpaceID>,
        sharingName: String? = nil,
        eventHandler: @escaping @Sendable (NetworkV1NodeEvent) -> Void = { _ in }
    ) {
        self.peerID = peerID
        self.repository = repository
        self.selectedSpaces = selectedSpaces
        self.sharingName = NetworkV1SharingName.sanitized(
            sharingName ?? NetworkV1SharingName.currentDeviceName
        )
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
        let localInstanceID = UUID().uuidString.lowercased()
        self.localInstanceID = localInstanceID
        listener.service = NWListener.Service(
            name: sharingName,
            type: Self.serviceType,
            domain: Self.serviceDomain,
            txtRecord: try? NetworkV1DiscoveryRecord(
                peerID: peerID,
                instanceID: localInstanceID,
                sharingName: sharingName
            ).encodedTXTData()
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
            self.candidateInstanceTracker.removeAll()
            self.retryItems.values.forEach { $0.cancel() }
            self.retryItems.removeAll()
            self.retryAttempts.removeAll()
            self.pendingApplicationMessages.removeAll()
            self.localInstanceID = nil
        }
    }

    /// Replaces the spaces offered and selected by future v1 handshakes.
    /// Existing links reconnect because v1 selections are immutable per connection.
    public func setActiveSpaces(_ spaces: Set<SpaceID>) async {
        await repository.replaceOfferedSpaces(with: spaces)
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                guard self.selectedSpaces != spaces else {
                    continuation.resume()
                    return
                }
                self.selectedSpaces = spaces
                self.links.values.forEach { $0.cancel() }
                continuation.resume()
            }
        }
    }

    /// Clears retained networking history and renegotiates every direct link.
    public func resetHistory(keeping spaces: Set<SpaceID>) async {
        await repository.removeAllHistory(keeping: spaces)
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.selectedSpaces = spaces
                self.links.values.forEach { $0.cancel() }
                continuation.resume()
            }
        }
    }

    /// Appends a local operation and immediately offers it to every live direct neighbor.
    @discardableResult
    public func publish(_ operation: EditOperation) async -> NetworkV1ImportResult {
        await publish([operation])[0]
    }

    /// Appends one logical application batch and offers it to every live peer
    /// as a single protocol batch.
    @discardableResult
    public func publish(_ operations: [EditOperation]) async -> [NetworkV1ImportResult] {
        guard !operations.isEmpty else { return [] }
        let results = await repository.seedLocalHistory(operations)
        let appended = zip(operations, results).compactMap { operation, result in
            result == .appended ? operation : nil
        }
        guard !appended.isEmpty else { return results }
        queue.async { [weak self] in
            self?.peerLinks.values.forEach { $0.publish(appended) }
        }
        return results
    }

    /// Imports an application's already-retained operation log without sending
    /// it as a stream of live updates. Existing links are renegotiated so each
    /// neighbor can request only the ranges it is missing.
    @discardableResult
    public func seedLocalHistory(_ operations: [EditOperation]) async -> [NetworkV1ImportResult] {
        let results = await repository.seedLocalHistory(operations)
        guard results.contains(.appended) else { return results }
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.links.values.forEach { $0.cancel() }
                continuation.resume()
            }
        }
        return results
    }

    /// Makes retained operations available and re-advertises the resulting
    /// ranges to one already-synchronized peer. Unlike `seedLocalHistory`, this
    /// keeps the link alive so an app-level restore cannot cause a reconnect
    /// loop while the peer requests its missing ranges.
    @discardableResult
    public func offerHistory(
        _ operations: [EditOperation],
        to peerID: NetworkPeerID
    ) async -> [NetworkV1ImportResult] {
        let results = await repository.seedLocalHistory(operations)
        let link: NetworkV1Link? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.peerLinks[peerID])
            }
        }
        await link?.reconcileHistory()
        return results
    }

    /// Sends ephemeral application data to every synchronized direct peer.
    public func broadcast(channel: String, payload: Data) {
        let message = NetworkV1ApplicationMessage(channel: channel, payload: payload)
        queue.async { [weak self] in
            self?.peerLinks.values.forEach { $0.sendApplicationMessage(message) }
        }
    }

    /// Sends ephemeral application data to one synchronized direct peer.
    public func send(channel: String, payload: Data, to peerID: NetworkPeerID) {
        let message = NetworkV1ApplicationMessage(channel: channel, payload: payload)
        queue.async { [weak self] in
            guard let self else { return }
            if let link = self.peerLinks[peerID] {
                link.sendApplicationMessage(message)
            } else {
                var pending = self.pendingApplicationMessages[peerID, default: []]
                if pending.count == 256 { pending.removeFirst() }
                pending.append(message)
                self.pendingApplicationMessages[peerID] = pending
            }
        }
    }

    public func connectedPeerIDs() async -> Set<NetworkPeerID> {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: Set(self?.peerLinks.keys.map { $0 } ?? []))
            }
        }
    }

    public func broadcastPresence(_ envelope: PresenceEnvelope) throws {
        broadcast(channel: PresenceEnvelope.kind, payload: try PresenceCodec.encode(envelope))
    }

    public func sendPresence(_ envelope: PresenceEnvelope, to peerID: NetworkPeerID) throws {
        send(channel: PresenceEnvelope.kind, payload: try PresenceCodec.encode(envelope), to: peerID)
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var seenPeers: Set<NetworkPeerID> = []
        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata,
                  let record = try? NetworkV1DiscoveryRecord(txtValues: txtRecord.dictionary),
                  record.networkVersions.contains(1), record.operationVersions.contains(1),
                  record.capabilities.contains("tcp"), record.capabilities.contains("history-ranges"),
                  record.peerID != peerID else { continue }
            seenPeers.insert(record.peerID)
            if let instanceID = record.instanceID {
                switch candidateInstanceTracker.consider(instanceID, for: record.peerID) {
                case .replaced:
                    retryItems.removeValue(forKey: record.peerID)?.cancel()
                    retryAttempts.removeValue(forKey: record.peerID)
                    connectingPeers.remove(record.peerID)
                    if let staleLink = peerLinks.removeValue(forKey: record.peerID) {
                        staleLink.cancel()
                        eventHandler(.disconnected(record.peerID, "peer instance changed"))
                    }
                case .superseded:
                    // Bonjour can retain the terminated process's result while
                    // publishing its replacement. Never let that stale result
                    // overwrite the replacement endpoint on a later set pass.
                    continue
                case .selected, .current:
                    break
                }
            }
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
            localInstanceID: localInstanceID,
            expectedRemotePeerID: expectedPeerID,
            repository: repository,
            selectedSpaces: selectedSpaces
        )
        let link = NetworkV1Link(connection: connection, session: session, outbound: outbound, queue: queue)
        let identifier = ObjectIdentifier(link)
        links[identifier] = link
        link.onIdentified = { [weak self, weak link] hello in
            guard let self, let link else { return false }
            let remotePeerID = hello.peerID
            let correctDirection = outbound ? self.peerID < remotePeerID : self.peerID > remotePeerID
            guard correctDirection else { return false }
            var replacedProcess = false
            if let instanceID = hello.instanceID {
                switch self.candidateInstanceTracker.consider(instanceID, for: remotePeerID) {
                case .replaced:
                    replacedProcess = true
                case .superseded:
                    return false
                case .selected, .current:
                    break
                }
            }
            if let existing = self.peerLinks[remotePeerID] {
                if !replacedProcess {
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
                }
                existing.cancel()
            }
            self.peerLinks[remotePeerID] = link
            self.connectingPeers.remove(remotePeerID)
            self.retryItems.removeValue(forKey: remotePeerID)?.cancel()
            self.retryAttempts.removeValue(forKey: remotePeerID)
            self.eventHandler(.connected(remotePeerID))
            for message in self.pendingApplicationMessages.removeValue(forKey: remotePeerID) ?? [] {
                link.sendApplicationMessage(message)
            }
            return true
        }
        link.onEvent = { [weak self] event in self?.eventHandler(event) }
        link.onClosed = { [weak self, weak link] remotePeerID, error in
            guard let self else { return }
            self.queue.async {
                self.links.removeValue(forKey: identifier)
                var removedCurrentLink = false
                if let remotePeerID, self.peerLinks[remotePeerID] === link {
                    self.peerLinks.removeValue(forKey: remotePeerID)
                    removedCurrentLink = true
                }
                let retryPeerID = remotePeerID ?? expectedPeerID
                if let retryPeerID {
                    self.connectingPeers.remove(retryPeerID)
                    self.scheduleRetry(for: retryPeerID)
                }
                if remotePeerID == nil || removedCurrentLink {
                    self.eventHandler(.disconnected(remotePeerID, error))
                }
            }
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

}

private final class NetworkV1Link: @unchecked Sendable {
    let connection: NWConnection
    let session: NetworkV1Session
    let outbound: Bool
    let queue: DispatchQueue
    var onIdentified: ((NetworkV1Hello) -> Bool)?
    var onEvent: ((NetworkV1NodeEvent) -> Void)?
    var onClosed: ((NetworkPeerID?, String?) -> Void)?

    private var frameCodec = NetworkV1FrameCodec()
    private var remotePeerID: NetworkPeerID?
    private var didClose = false
    private var didSynchronize = false
    private var timeoutItem: DispatchWorkItem?
    private var pendingApplicationMessages: [NetworkV1ApplicationMessage] = []
    private var inboundProcessingTask: Task<Void, Never>?
    private var outboundOperationTask: Task<Void, Never>?

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

    func publish(_ operations: [EditOperation]) {
        guard !operations.isEmpty else { return }
        let previousTask = outboundOperationTask
        outboundOperationTask = Task {
            await previousTask?.value
            guard let message = await session.liveBatch(for: operations) else { return }
            await send([message])
        }
    }

    func sendApplicationMessage(_ message: NetworkV1ApplicationMessage) {
        Task {
            if await session.state == .live {
                guard let outgoing = await session.applicationMessage(message) else { return }
                await send([outgoing])
            } else {
                if pendingApplicationMessages.count == 256 {
                    pendingApplicationMessages.removeFirst()
                }
                pendingApplicationMessages.append(message)
            }
        }
    }

    func reconcileHistory() async {
        await send(await session.reconciliationMessages())
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.armTimeout(seconds: 120)
                do {
                    let messages = try self.frameCodec.append(data).map(NetworkV1MessageCodec.decode)
                    self.enqueueInbound(messages)
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

    private func enqueueInbound(_ messages: [NetworkV1Message]) {
        guard !messages.isEmpty else { return }
        let previousTask = inboundProcessingTask
        inboundProcessingTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            for message in messages {
                await self.process(message)
            }
        }
    }

    private func process(_ message: NetworkV1Message) async {
        if case .hello(let hello) = message, remotePeerID == nil {
            guard await identify(hello) else {
                await send([.error(NetworkV1ErrorMessage(code: .peerIDMismatch, message: "Duplicate or incorrectly directed connection"))])
                close("Duplicate or incorrectly directed connection")
                return
            }
            remotePeerID = hello.peerID
        }
        do {
            let responses = try await session.receive(message)
            await send(responses)
            if case .operationBatch(let batch) = message, let remotePeerID {
                for envelope in batch.envelopes {
                    for operation in envelope.operations where await session.hasAccepted(operation) {
                        onEvent?(.received(operation, from: remotePeerID))
                    }
                }
            }
            if case .application(let application) = message, let remotePeerID {
                if application.channel == PresenceEnvelope.kind,
                   let presence = try? PresenceCodec.decode(application.payload) {
                    onEvent?(.receivedPresence(presence, from: remotePeerID))
                } else {
                    onEvent?(.receivedApplicationMessage(application, from: remotePeerID))
                }
            }
            let state = await session.state
            switch state {
            case .hello, .selection: armTimeout(seconds: 30)
            case .synchronizing: armTimeout(seconds: 120)
            case .live:
                cancelTimeout()
                if !didSynchronize {
                    didSynchronize = true
                    let pending = pendingApplicationMessages
                    pendingApplicationMessages.removeAll()
                    for message in pending {
                        if let outgoing = await session.applicationMessage(message) {
                            await send([outgoing])
                        }
                    }
                    if let remotePeerID { onEvent?(.synchronized(remotePeerID)) }
                }
            case .closed: cancelTimeout()
            }
        } catch NetworkV1SessionError.protocolError(let error) {
            onEvent?(.error(error, from: remotePeerID))
            if error.fatal { close(error.message) }
        } catch {
            close(error.localizedDescription)
        }
    }

    private func identify(_ hello: NetworkV1Hello) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.onIdentified?(hello) == true)
            }
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
