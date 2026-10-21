// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DepthBokeh",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // 纯 Swift 景深渲染引擎：不依赖任何 Apple 框架，可在 iOS / macOS / Linux 编译
        .library(name: "BokehCore", targets: ["BokehCore"]),
        // iOS 相机层：AVFoundation 采集画面 + 深度，交给 BokehCore 渲染
        .library(name: "BokehCamera", targets: ["BokehCamera"]),
    ],
    targets: [
        .target(name: "BokehCore"),
        .target(name: "BokehCamera", dependencies: ["BokehCore"], resources: [.process("Resources")]),
        // 命令行工具：读 PPM 图像 + PFM 视差图，输出虚化结果（用于在电脑上调试算法）
        .executableTarget(name: "bokeh-cli", dependencies: ["BokehCore"]),
        .testTarget(name: "BokehCoreTests", dependencies: ["BokehCore"]),
    ]
)
