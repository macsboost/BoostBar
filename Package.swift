// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BoostBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BoostBar",
            path: "Sources/BoostBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("WebKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
            ]
        )
    ]
)
