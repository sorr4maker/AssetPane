// swift-tools-version: 6.0
import PackageDescription

// 资产窗 AssetPane：菜单栏 + 桌面面板，里面装的是 real-time-fund（基估宝）打包出来的静态页面。
let package = Package(
    name: "AssetPane",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AssetPane"),
    ],
    swiftLanguageModes: [.v5]
)
