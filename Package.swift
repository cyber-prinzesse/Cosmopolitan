// swift-tools-version:6.2
// `swift build` for development checks. The shipped app is still made by scripts/build.sh (bundle, Info.plist, embedded Sparkle,
// dSYM, signing); both compile the same sources. The C++ module is its own target here, imported where Swift calls it.
import PackageDescription

let package = Package(
    name: "Cosmopolitan",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CosmoNative", path: "Sources/Native", publicHeadersPath: ".",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .executableTarget(name: "Cosmopolitan", dependencies: ["CosmoNative", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources", exclude: ["Native"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ],
    cxxLanguageStandard: .cxx17   // same as scripts/build.sh (clang's default would be C++14)
)
