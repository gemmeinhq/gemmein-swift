// swift-tools-version:5.9
// GemmeinSwift — W10 §1 B. The Swift SDK: the same HTTP contract, the same
// method names, in Swift idiom. No dependencies: the whole package is
// Foundation + Security, so an app adds it and ships.
import PackageDescription

let package = Package(
    name: "GemmeinSwift",
    // iOS 17 is the product's floor. macOS 14 is here so `swift test` runs on
    // a Mac host — the contract ring (ring 3) drives a local engine from the
    // command line, and a package that only builds for a simulator could not
    // be tested that way.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GemmeinSwift", targets: ["GemmeinSwift"])
    ],
    targets: [
        .target(name: "GemmeinSwift"),
        .testTarget(name: "GemmeinSwiftTests", dependencies: ["GemmeinSwift"])
    ]
)
