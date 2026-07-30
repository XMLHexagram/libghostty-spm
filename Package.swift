// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Per-arch xcframeworks rather than one universal.
//
// `libghostty.a` is a STATIC library, so the linker only ever pulls the slice it
// needs and a universal one costs nothing in the shipped app. What it does cost
// is the download: 38 MB fetched to link 19 MB of it. Two assets, one per arch,
// halve that — at the price of the manifest having to know which arch is being
// built, which SPM gives no direct way to express (a `binaryTarget` takes one
// URL, and manifests are evaluated before any target's arch is settled).
//
// Hence the environment variable. Set `LIBGHOSTTY_ARCH=x86_64` for the
// Intel build; anything else (including unset) resolves arm64.
//
// KNOWN SHARP EDGE: an Xcode GUI build of an Intel scheme won't have the
// variable set and will resolve the arm64 slice, failing to link with
// "symbol(s) not found for architecture x86_64". Xcode Cloud and any script
// build must pass it explicitly. That is the trade for the smaller download —
// if it becomes a nuisance, going back to one universal asset is a two-line
// change here.
let libghosttyArch = ProcessInfo.processInfo.environment["LIBGHOSTTY_ARCH"] ?? "arm64"
let libghosttyBinary: (url: String, checksum: String) = libghosttyArch == "x86_64"
    ? ("https://github.com/XMLHexagram/libghostty-spm/releases/download/boite-mirror.1.3.0/GhosttyKit-x86_64.xcframework.zip", "f3f8539c10794efb9a9b1124aeea27468e3749322c605936a60d4cbc4a59a3dd")
    : ("https://github.com/XMLHexagram/libghostty-spm/releases/download/boite-mirror.1.3.0/GhosttyKit-arm64.xcframework.zip", "4be77699c0070ad4010db6e258204440194f3bba06f882c7b08d12f5584e6cb8")

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "ShellCraftKit", targets: ["ShellCraftKit"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "ShellCraftKit",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/ShellCraftKit"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: libghosttyBinary.url,
            checksum: libghosttyBinary.checksum
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit"]
        ),
    ]
)
