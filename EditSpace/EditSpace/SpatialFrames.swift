import Foundation

/// Standard EditSpace spatial-frame profile carried by ordinary durable operations.
public enum SpatialFrameProfile {
    public static let version = 1
    public static let framedCapability = "spatial-frames"
    public static let alignmentNotApplicableCapability = "spatial-alignment-not-applicable"

    public static let frameObjectType = "frame"
    public static let frameLinkObjectType = "frameLink"
}

public typealias SpatialAlignmentMethod = ProtocolToken

public extension SpatialAlignmentMethod {
    static let arkitCollaboration: Self = "arkitCollaboration"
    static let aprilTag: Self = "aprilTag"
    static let manual: Self = "manual"
}

/// A finite column-major 4×4 transform mapping coordinates between frames.
public struct SpatialMatrix: Equatable, Sendable {
    public static let identity = SpatialMatrix(uncheckedValues: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ])

    public let values: [Double]

    public init?(_ values: [Double]) {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        self.values = values
    }

    private init(uncheckedValues: [Double]) {
        values = uncheckedValues
    }

    public func multiplied(by rhs: SpatialMatrix) -> SpatialMatrix {
        var result = Array(repeating: 0.0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                result[column * 4 + row] = (0..<4).reduce(0) { partial, index in
                    partial + values[index * 4 + row] * rhs.values[column * 4 + index]
                }
            }
        }
        return SpatialMatrix(uncheckedValues: result)
    }

    public var inverted: SpatialMatrix? {
        var augmented = (0..<4).map { row in
            (0..<4).map { column in values[column * 4 + row] }
                + (0..<4).map { column in row == column ? 1.0 : 0.0 }
        }
        for pivotColumn in 0..<4 {
            guard let pivotRow = (pivotColumn..<4).max(by: {
                abs(augmented[$0][pivotColumn]) < abs(augmented[$1][pivotColumn])
            }), abs(augmented[pivotRow][pivotColumn]) > 1e-12 else { return nil }
            if pivotRow != pivotColumn {
                augmented.swapAt(pivotRow, pivotColumn)
            }
            let pivot = augmented[pivotColumn][pivotColumn]
            for column in 0..<8 {
                augmented[pivotColumn][column] /= pivot
            }
            for row in 0..<4 where row != pivotColumn {
                let factor = augmented[row][pivotColumn]
                for column in 0..<8 {
                    augmented[row][column] -= factor * augmented[pivotColumn][column]
                }
            }
        }
        var result = Array(repeating: 0.0, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                result[column * 4 + row] = augmented[row][column + 4]
            }
        }
        return SpatialMatrix(result)
    }
}

public struct SpatialFrame: Equatable, Sendable {
    public let id: EntityID
    public let createdAt: Date?
    public let actorID: ActorID
    public let operationID: OperationID
}

public struct SpatialFrameLink: Equatable, Sendable {
    public let id: EntityID
    public let frameA: EntityID
    public let frameB: EntityID
    public let bInA: SpatialMatrix
    public let method: SpatialAlignmentMethod?
    public let createdAt: Date?
    public let operationID: OperationID
}

/// Resolves spatial-frame islands deterministically from immutable EditSpace history.
public struct SpatialFrameGraph: Sendable {
    public let frames: [EntityID: SpatialFrame]
    public let links: [SpatialFrameLink]

    public init(operations: [EditOperation]) {
        var parsedFrames: [EntityID: SpatialFrame] = [:]
        var parsedLinks: [SpatialFrameLink] = []
        for operation in operations where operation.action == .create && operation.entity == .object {
            guard let targetID = operation.targetID,
                  let objectType = operation.fields[SceneField.objectType.rawValue]?.stringValue else { continue }
            if objectType == SpatialFrameProfile.frameObjectType {
                parsedFrames[targetID] = SpatialFrame(
                    id: targetID,
                    createdAt: operation.createdAt,
                    actorID: operation.actorID,
                    operationID: operation.operationID
                )
            } else if objectType == SpatialFrameProfile.frameLinkObjectType,
                      let frameA = operation.fields[SceneField.frameA.rawValue]?.stringValue,
                      let frameB = operation.fields[SceneField.frameB.rawValue]?.stringValue,
                      let values = operation.fields[SceneField.bInA.rawValue]?.arrayValue?.compactMap(\.numberValue),
                      let matrix = SpatialMatrix(values) {
                parsedLinks.append(SpatialFrameLink(
                    id: targetID,
                    frameA: EntityID(rawValue: frameA),
                    frameB: EntityID(rawValue: frameB),
                    bInA: matrix,
                    method: operation.fields[SceneField.alignmentMethod.rawValue]?.stringValue.map {
                        SpatialAlignmentMethod(rawValue: $0)
                    },
                    createdAt: operation.createdAt,
                    operationID: operation.operationID
                ))
            }
        }
        frames = parsedFrames
        links = parsedLinks.sorted(by: Self.linkComesBefore)
    }

    public var rootFrameID: EntityID? {
        frames.values.min(by: Self.frameComesBefore)?.id
    }

    public func rootFrameID(containing frameID: EntityID) -> EntityID? {
        guard frames[frameID] != nil else { return nil }
        return reachableFrames(from: frameID).compactMap { frames[$0] }.min(by: Self.frameComesBefore)?.id
    }

    public func transformToRoot(from frameID: EntityID) -> SpatialMatrix? {
        guard let rootID = rootFrameID(containing: frameID) else { return nil }
        if rootID == frameID { return .identity }
        var queue: [(EntityID, SpatialMatrix)] = [(rootID, .identity)]
        var visited: Set<EntityID> = [rootID]
        while !queue.isEmpty {
            let (current, rootFromCurrent) = queue.removeFirst()
            for edge in edges(from: current) where visited.insert(edge.frameID).inserted {
                let rootFromNeighbor = rootFromCurrent.multiplied(by: edge.currentFromNeighbor)
                if edge.frameID == frameID { return rootFromNeighbor }
                queue.append((edge.frameID, rootFromNeighbor))
            }
        }
        return nil
    }

    public func transform(from sourceFrameID: EntityID, to destinationFrameID: EntityID) -> SpatialMatrix? {
        guard rootFrameID(containing: sourceFrameID) == rootFrameID(containing: destinationFrameID),
              let rootFromSource = transformToRoot(from: sourceFrameID),
              let rootFromDestination = transformToRoot(from: destinationFrameID),
              let destinationFromRoot = rootFromDestination.inverted else { return nil }
        return destinationFromRoot.multiplied(by: rootFromSource)
    }

    private func reachableFrames(from start: EntityID) -> Set<EntityID> {
        var result: Set<EntityID> = [start]
        var queue = [start]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for edge in edges(from: current) where result.insert(edge.frameID).inserted {
                queue.append(edge.frameID)
            }
        }
        return result
    }

    private func edges(from frameID: EntityID) -> [(frameID: EntityID, currentFromNeighbor: SpatialMatrix)] {
        links.compactMap { link in
            if link.frameA == frameID { return (link.frameB, link.bInA) }
            if link.frameB == frameID, let inverse = link.bInA.inverted { return (link.frameA, inverse) }
            return nil
        }
    }

    private static func frameComesBefore(_ lhs: SpatialFrame, _ rhs: SpatialFrame) -> Bool {
        let leftDate = lhs.createdAt ?? .distantFuture
        let rightDate = rhs.createdAt ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        if lhs.actorID != rhs.actorID { return lhs.actorID < rhs.actorID }
        return lhs.operationID < rhs.operationID
    }

    private static func linkComesBefore(_ lhs: SpatialFrameLink, _ rhs: SpatialFrameLink) -> Bool {
        let leftDate = lhs.createdAt ?? .distantFuture
        let rightDate = rhs.createdAt ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.operationID < rhs.operationID
    }
}
