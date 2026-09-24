// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Locus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Locus",
            path: "App",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("MapKit"),
                .linkedFramework("CoreLocation"),
            ]
        )
    ]
)
