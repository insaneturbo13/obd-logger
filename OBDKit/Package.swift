// swift-tools-version:5.10
import PackageDescription

// Protocol core for the logger: no UIKit/CoreBluetooth dependencies, so it builds and
// tests on Linux and Windows with the plain Swift toolchain.
let package = Package(
    name: "OBDKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OBDKit", targets: ["OBDKit"]),
    ],
    targets: [
        .target(name: "OBDKit"),
        .testTarget(
            name: "OBDKitTests",
            dependencies: ["OBDKit"],
            exclude: ["Fixtures"]
        ),
    ]
)
