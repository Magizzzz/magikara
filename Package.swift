// swift-tools-version: 6.0
import PackageDescription

// MaGi Kara — 日语 AI 卡拉 OK 字幕工作台
//
// MaGiKaraKit     : 数据模型 / 读音 / 音频分析 / 对轨 / 工程 / 导出（可测试，可无头运行）
// MaGiKara        : SwiftUI macOS App 外壳
// magikara-phase0 : Phase 0 无头命令行，跑测试集并输出真实指标
//
// 说明：
// - 用 tools-version 6.0 是为了启用 swift-testing（本机只有 Command Line Tools，
//   没有随 Xcode 提供的 XCTest）；语言模式仍固定为 Swift 5，避免严格并发带来的噪音。
// - 没有 Xcode，因此 .app 由 Scripts/build.sh 手工组装。
let package = Package(
    name: "MaGiKara",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MaGiKara", targets: ["MaGiKara"]),
        .executable(name: "magikara-phase0", targets: ["MaGiKaraPhase0"]),
        .library(name: "MaGiKaraKit", targets: ["MaGiKaraKit"]),
    ],
    targets: [
        .target(
            name: "MaGiKaraKit",
            resources: [
                .copy("Resources/logo.png"),
                .copy("Resources/local_forced_aligner"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MaGiKara",
            dependencies: ["MaGiKaraKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MaGiKaraPhase0",
            dependencies: ["MaGiKaraKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MaGiKaraKitTests",
            dependencies: ["MaGiKaraKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
