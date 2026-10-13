// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Patchbay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "Patchbay",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Patchbay"
        ),
    ]
)
