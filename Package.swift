// swift-tools-version: 6.0
import PackageDescription

// Логика вынесена в LimitNotifierCore, чтоб её можно было тестировать.
// Исполняемый таргет тестами не покрывается, это только склейка и UI.
let package = Package(
    name: "LimitNotifier",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LimitNotifierCore",
            path: "Sources/LimitNotifierCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LimitNotifier",
            dependencies: ["LimitNotifierCore"],
            path: "Sources/LimitNotifier",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LimitNotifierCoreTests",
            dependencies: ["LimitNotifierCore"],
            path: "Tests/LimitNotifierCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
