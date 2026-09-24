// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Switchboard", targets: ["Switchboard"])],
    targets: [
        .target(name: "SwitchboardCore"),
        .executableTarget(name: "Switchboard", dependencies: ["SwitchboardCore"]),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"])
    ]
)
