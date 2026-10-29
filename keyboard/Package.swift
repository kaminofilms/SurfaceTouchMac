// swift-tools-version:5.9
// SurfaceTouchMac user-space components.
//  - TouchKeyboardCore: layout, key logic and focus classification (no AppKit, unit-tested)
//  - SurfaceTouchKeys:  the on-screen keyboard app (AppKit)
//  - SurfaceSetupCore:  hardware / internal-disk validation logic (unit-tested with fixtures)
//  - stm-setup:         command-line tool used by the installer package
import PackageDescription

let package = Package(
    name: "SurfaceTouchMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SurfaceTouchKeys", targets: ["SurfaceTouchKeys"]),
        .executable(name: "stm-setup", targets: ["stm-setup"]),
    ],
    targets: [
        .target(name: "TouchKeyboardCore"),
        .executableTarget(name: "SurfaceTouchKeys", dependencies: ["TouchKeyboardCore"]),
        .target(name: "SurfaceSetupCore"),
        .executableTarget(name: "stm-setup", dependencies: ["SurfaceSetupCore"]),
        .testTarget(name: "TouchKeyboardCoreTests", dependencies: ["TouchKeyboardCore"]),
        .testTarget(name: "SurfaceSetupCoreTests", dependencies: ["SurfaceSetupCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
