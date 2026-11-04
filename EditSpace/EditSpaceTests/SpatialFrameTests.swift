import Foundation
import Testing
@testable import EditSpace

@Suite("EditSpace spatial frames")
struct SpatialFrameTests {
    private let spaceID = SpaceID(rawValue: "shared-space")

    @Test("Root and path are deterministic by creation metadata")
    func deterministicRootAndPath() throws {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let frameA = frame(id: "frame-a", actor: "z", sequence: 9, createdAt: older)
        let frameB = frame(id: "frame-b", actor: "a", sequence: 1, createdAt: newer)
        let bInA = try #require(SpatialMatrix([
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            2, 3, 4, 1
        ]))
        let link = EditOperation(
            spaceID: spaceID,
            actorID: ActorID(rawValue: "linker"),
            sequence: 1,
            action: .create,
            entity: .object,
            targetID: EntityID(rawValue: "link"),
            fields: [
                SceneField.objectType.rawValue: .string(SpatialFrameProfile.frameLinkObjectType),
                SceneField.frameA.rawValue: .string("frame-a"),
                SceneField.frameB.rawValue: .string("frame-b"),
                SceneField.bInA.rawValue: .matrix(bInA.values)
            ],
            requiredFeatures: [.spatialFramesV1],
            createdAt: newer
        )

        let graph = SpatialFrameGraph(operations: [frameB, link, frameA])

        #expect(graph.rootFrameID(containing: EntityID(rawValue: "frame-b"))?.rawValue == "frame-a")
        #expect(graph.transformToRoot(from: EntityID(rawValue: "frame-b")) == bInA)
    }

    @Test("Actor breaks equal-time root ties without sequence ordering")
    func rootTieBreak() {
        let date = Date(timeIntervalSince1970: 10)
        let frameZ = frame(id: "frame-z", actor: "z", sequence: 1, createdAt: date)
        let frameA = frame(id: "frame-a", actor: "a", sequence: 99, createdAt: date)

        #expect(SpatialFrameGraph(operations: [frameZ, frameA]).rootFrameID?.rawValue == "frame-a")
    }

    private func frame(id: String, actor: String, sequence: Int64, createdAt: Date) -> EditOperation {
        EditOperation(
            spaceID: spaceID,
            actorID: ActorID(rawValue: actor),
            sequence: sequence,
            action: .create,
            entity: .object,
            targetID: EntityID(rawValue: id),
            fields: [
                SceneField.objectType.rawValue: .string(SpatialFrameProfile.frameObjectType),
                SceneField.transform.rawValue: .matrix(SpatialMatrix.identity.values),
                SceneField.parentID.rawValue: .null
            ],
            requiredFeatures: [.spatialFramesV1],
            createdAt: createdAt
        )
    }
}
