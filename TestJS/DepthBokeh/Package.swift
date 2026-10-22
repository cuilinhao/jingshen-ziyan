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
        // 景深渲染的 GPU 版（Metal），和 BokehCore 的 CPU 参考实现结果一致；只在 Apple 平台上有内容
        .library(name: "BokehMetal", targets: ["BokehMetal"]),
    ],
    targets: [
        .target(name: "BokehCore"),
        .target(name: "BokehMetal", dependencies: ["BokehCore"]),
        .target(name: "BokehCamera", dependencies: ["BokehCore", "BokehMetal"], resources: [.process("Resources")]),
        // 命令行工具：读 PPM 图像 + PFM 视差图，输出虚化结果（用于在电脑上调试算法）
        .executableTarget(name: "bokeh-cli", dependencies: ["BokehCore"]),
        .testTarget(name: "BokehCoreTests", dependencies: ["BokehCore"]),
        // GPU 和 CPU 逐像素对比（在 Mac 上 `swift test` 时跑真的 GPU）
        .testTarget(name: "BokehMetalTests", dependencies: ["BokehMetal", "BokehCore"]),
    ]
)
