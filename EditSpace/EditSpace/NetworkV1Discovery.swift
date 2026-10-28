import Foundation

public enum NetworkV1DiscoveryError: Error, Equatable, Sendable {
    case missingRequiredKey(String)
    case invalidPeerID
    case invalidVersions(String)
    case invalidCapabilities
    case oversizedEntry
    case oversizedRecord
    case malformedRecord
    case duplicateKey(String)
}

public struct NetworkV1DiscoveryRecord: Equatable, Sendable {
    public let networkVersions: [Int]
    public let operationVersions: [Int]
    public let peerID: NetworkPeerID
    public let capabilities: [String]
    public let instanceID: String?
    public let sharingName: String?

    public init(
        networkVersions: [Int] = [1],
        operationVersions: [Int] = [1],
        peerID: NetworkPeerID,
        capabilities: [String] = ["application-messages", "history-ranges", "tcp"],
        instanceID: String? = nil,
        sharingName: String? = nil
    ) throws {
        let sortedNetworkVersions = networkVersions.sorted(by: >)
        let sortedOperationVersions = operationVersions.sorted(by: >)
        let sortedCapabilities = capabilities.sorted()
        guard Self.validVersions(sortedNetworkVersions), Set(networkVersions).count == networkVersions.count else {
            throw NetworkV1DiscoveryError.invalidVersions("net")
        }
        guard Self.validVersions(sortedOperationVersions), Set(operationVersions).count == operationVersions.count else {
            throw NetworkV1DiscoveryError.invalidVersions("ops")
        }
        guard peerID.isCanonical else { throw NetworkV1DiscoveryError.invalidPeerID }
        guard Set(capabilities).count == capabilities.count,
              sortedCapabilities.allSatisfy(Self.validCapability),
              sortedCapabilities.contains("tcp"), sortedCapabilities.contains("history-ranges") else {
            throw NetworkV1DiscoveryError.invalidCapabilities
        }
        self.networkVersions = sortedNetworkVersions
        self.operationVersions = sortedOperationVersions
        self.peerID = peerID
        self.capabilities = sortedCapabilities
        self.instanceID = instanceID
        self.sharingName = sharingName
    }

    public init(txtValues: [String: String]) throws {
        for key in ["net", "ops", "peer", "caps"] where txtValues[key] == nil {
            throw NetworkV1DiscoveryError.missingRequiredKey(key)
        }
        let networkVersions = try Self.parseVersions(txtValues["net"]!, key: "net")
        let operationVersions = try Self.parseVersions(txtValues["ops"]!, key: "ops")
        let peerID = NetworkPeerID(rawValue: txtValues["peer"]!)
        let capabilities = txtValues["caps"]!.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard capabilities == capabilities.sorted() else {
            throw NetworkV1DiscoveryError.invalidCapabilities
        }
        try self.init(
            networkVersions: networkVersions,
            operationVersions: operationVersions,
            peerID: peerID,
            capabilities: capabilities,
            instanceID: txtValues["instance"],
            sharingName: txtValues["name"]
        )
    }

    public init(txtData: Data) throws {
        guard txtData.count <= 1_300 else { throw NetworkV1DiscoveryError.oversizedRecord }
        var index = txtData.startIndex
        var values: [String: String] = [:]
        while index < txtData.endIndex {
            let length = Int(txtData[index])
            index = txtData.index(after: index)
            guard length > 0, txtData.distance(from: index, to: txtData.endIndex) >= length else {
                throw NetworkV1DiscoveryError.malformedRecord
            }
            let end = txtData.index(index, offsetBy: length)
            guard let entry = String(data: txtData[index..<end], encoding: .utf8),
                  let separator = entry.firstIndex(of: "=") else {
                throw NetworkV1DiscoveryError.malformedRecord
            }
            let key = String(entry[..<separator])
            guard values[key] == nil else { throw NetworkV1DiscoveryError.duplicateKey(key) }
            values[key] = String(entry[entry.index(after: separator)...])
            index = end
        }
        try self.init(txtValues: values)
    }

    public var txtValues: [String: String] {
        var values = [
            "net": networkVersions.map(String.init).joined(separator: ","),
            "ops": operationVersions.map(String.init).joined(separator: ","),
            "peer": peerID.rawValue,
            "caps": capabilities.joined(separator: ",")
        ]
        if let instanceID {
            values["instance"] = instanceID
        }
        if let sharingName {
            values["name"] = sharingName
        }
        return values
    }

    public func encodedTXTData() throws -> Data {
        var data = Data()
        for (key, value) in txtValues.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { throw NetworkV1DiscoveryError.oversizedEntry }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        guard data.count <= 1_300 else { throw NetworkV1DiscoveryError.oversizedRecord }
        return data
    }

    private static func parseVersions(_ value: String, key: String) throws -> [Int] {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let versions = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.first != "0", let version = Int(part), version > 0 else { return nil }
            return version
        }
        guard versions.count == parts.count, validVersions(versions) else {
            throw NetworkV1DiscoveryError.invalidVersions(key)
        }
        return versions
    }

    private static func validVersions(_ versions: [Int]) -> Bool {
        !versions.isEmpty && versions.count <= 32
            && versions == Array(Set(versions)).sorted(by: >)
    }

    private static func validCapability(_ capability: String) -> Bool {
        guard !capability.isEmpty else { return false }
        return capability.unicodeScalars.allSatisfy {
            (97...122).contains(Int($0.value))
                || (48...57).contains(Int($0.value))
                || $0.value == 45 || $0.value == 46
        }
    }
}
