// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EditSpace",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "EditSpace", targets: ["EditSpace"])
    ],
    targets: [
        .target(
            name: "EditSpace",
            path: "EditSpace/EditSpace",
            exclude: ["EditSpace.docc"]
        ),
        .testTarget(
            name: "EditSpaceTests",
            dependencies: ["EditSpace"],
            path: "EditSpace/EditSpaceTests"
        )
    ]
)
