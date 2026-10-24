// swift-tools-version: 5.9
import PackageDescription

// CrashKit：崩溃留痕（捕获 → 落盘 → 下次启动读取）。
//
// 只声明 iOS / macOS：这两个平台在本机有构建与测试路径。
// watchOS / tvOS 理论上可用（同一套 signal + NSException 接口），但没有验证过，不声明。
let package = Package(
    name: "CrashKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CrashKit", targets: ["CrashKit"]),
    ],
    targets: [
        .target(name: "CrashKit"),
        .testTarget(name: "CrashKitTests", dependencies: ["CrashKit"]),
    ]
)
