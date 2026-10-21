# DepthBokeh：用纯 Swift 实现 iPhone 人像模式的景深效果

这个项目复刻了 iPhone 相机「人像 → ƒ 景深」的效果：取景时可以实时拖动 ƒ 值、点按换对焦点，拍完以后还能重新调景深。

- **BokehCore**：景深渲染引擎，**纯 Swift**，只依赖 Foundation / Dispatch，不调用 Core Image、Metal 或任何现成的模糊滤镜。iOS、macOS、Linux 都能编译。
- **BokehCamera**：iOS 相机层，用 AVFoundation 同步采集视频帧和深度图，交给 BokehCore 渲染。
- **App/**：SwiftUI 界面（取景、ƒ 滑块、点按对焦、快门、拍后编辑），3 个文件。
- **bokeh-cli**：命令行工具，在电脑上用图片和深度图调试算法。

![测试场景的渲染结果](docs/demo.jpg)

## 在 iPhone 上运行

需要：Xcode 15 或更新版本、iOS 17 以上的真机（模拟器没有摄像头），机型要有**双摄或 LiDAR**（iPhone 11 及以后的绝大多数机型都可以；SE、XR 这类单摄机型不行）。

1. Xcode → New Project → iOS App（Interface 选 SwiftUI），最低部署版本设为 iOS 17。
2. 删掉模板自带的 `ContentView.swift` 和 `<项目名>App.swift`，把本项目 `App/` 下的 3 个文件拖进去。
3. File → Add Package Dependencies… → Add Local…，选择本项目根目录（`DepthBokeh`），把 `BokehCore` 和 `BokehCamera` 两个库加到 App target。
4. Target → Info 里添加两个权限说明：
   - `Privacy - Camera Usage Description`（NSCameraUsageDescription），比如「拍摄带深度信息的照片」
   - `Privacy - Photo Library Additions Usage Description`（NSPhotoLibraryAddUsageDescription），比如「保存虚化后的照片」
5. **Product → Scheme → Edit Scheme → Run → Build Configuration 改成 Release。** 这一步很重要：渲染器是纯 Swift 的 CPU 循环，Debug 模式不开优化，会慢 10 到 50 倍。
6. 选你的 iPhone，运行。
7. （可选，0.5× 超广角要用）把 `DepthAnythingV2SmallF16.mlpackage`（Apple 的 Core ML 版 Depth Anything V2，约 48 MB）拖进 App target。
   没打包的话，第一次切到 0.5× 时会从 Hugging Face（国内先试 hf-mirror.com）下载并在手机上编译。

### 变焦（0.5×–4×，和 DepthBokehCamera 2 一样）

点 0.5 / 1 / 2 / 4 跳过去（预览 0.3 秒平滑变焦），或者左右拖刻度连续调；松手时离数字 ±5% 以内会吸附过去。

| 倍率 | 实际用的相机 | App 裁切 | 深度 |
|---|---|---|---|
| 0.5×–0.99× | 超广角 | 1–1.98× | AI 单目深度 |
| 1×–1.99× | LiDAR（1×） | 1–1.99× | LiDAR |
| 2×–3.99× | 双摄广角（主摄原生 2×） | 1–1.99× | 双摄视差 |
| 4× | 双摄长焦 | 无 | 双摄视差 |

实时深度只在几个倍率点上有（iPhone 17 Pro Max：1×、2×、4×），两个点之间相机停在低的那个点，画面和深度图一起从中间裁。
拖动时只裁当前相机的画面，往小拖超过当前相机 5% 才马上换相机；松手约 0.3 秒后换到这个倍率最合适的相机。
换相机期间保留最后一帧，新相机出了 3 帧并且有深度（最多 0.8 秒）后淡入。路线规划在 `LensCatalog.swift`。

## 在电脑上调试算法

```bash
swift test                                   # 5 个单元测试
swift build -c release
.build/release/bokeh-cli in.ppm disparity.pfm out.ppm --f 2.8 --focus 0.6,0.55
```

输入是 8 位 PPM 图像和单通道 PFM 视差图（单位 1/米）。视差图分辨率可以比图像低，工具会自动补洞、上采样并做引导滤波。

## 算法

完整流程在 `Sources/BokehCore/BokehRenderer.swift`，每一步都有注释。

1. **深度对齐**（`DepthRefiner`）：iPhone 的视差图分辨率低、边缘发糊。先用 pull-push 补洞，再上采样到图像尺寸，最后用彩色图做**引导滤波**，让深度边缘贴合物体轮廓。
2. **虚拟镜头**（`LensParameters`）：薄透镜公式。弥散圆直径 ≈ (f² / N) × |视差 − 对焦点视差|，其中 N 是 ƒ 值。iPhone 的视差单位正好是 1/米，可以直接代进去。
3. **深度分层**：按带符号的模糊半径把画面切成十几层，靠近对焦面的地方切得更密。每个像素按线性权重分到相邻的两层，避免出现断层。
4. **圆盘模糊**：真实镜头的焦外是边缘清晰的**圆盘**，不是高斯。实现上用逐行前缀和，每个像素只要 O(r) 的计算量；圆盘边缘有亚像素级抗锯齿。半径大的层先降采样再模糊，计算量大约降到 1/q³。没有数据的 32×32 分块直接跳过。
5. **遮挡合成**：
   - 背景层从远到近用 over 方式合成，这样清晰的主体能完全挡住后面虚化的背景，边缘不会有光晕；
   - 被前景挡住、背景里缺数据的区域，用 **pull-push 从周围背景外推**来补。iPhone 前景虚化时物体边缘的「涂抹感」，就是这一步留下的痕迹；
   - 前景层用加法累积，再整体盖到背景上，前景的虚化会自然地向外扩散、边缘变成半透明。
6. **焦外光斑**：传感器上过曝的小亮点（灯珠、反光）在模糊前先提亮，模糊后才会变成明亮的光斑，而不是灰蒙蒙一片。大块的白色区域和锐化造成的边缘亮线不会被当成高光。

## 性能（在 2 核的 Linux 云主机上实测，Release 构建）

| 场景 | 深度处理 | 渲染 |
|---|---|---|
| 实时预览 480×360，ƒ2.8 | 25 ms | 约 50 ms |
| 照片 2048×1536，ƒ2.8 | 约 500 ms | 约 1.4 s |
| 照片 2048×1536，ƒ1.4 | 约 500 ms | 约 1.0 s |

iPhone 的核数更多、单核更快，实际应该比这快。我没在真机上测过，具体数字以你在设备上看到的为准：取景界面顶部会显示每帧耗时。

## 已知限制与可以改进的地方

- **物体边缘**：深度图在边缘处是「混合像素」，过渡区可能出现一圈轻微的暗边或半虚化带。可以用 Vision 的人像分割（`VNGeneratePersonSegmentationRequest`）或主体分割（`VNGenerateForegroundInstanceMaskRequest`）先修正边缘处的深度。iPhone 系统相机也是这么做的。
- **前景背后的内容是猜出来的**：摄像头没拍到被挡住的部分，只能外推。前景虚化越强，这一点越明显。
- **CPU 实现**：如果要全分辨率 4K 实时，可以把 `diskBlur` 移植到 Metal compute shader，算法本身不用改（只是 shader 不是 Swift 写的）。
- **双摄视差是「相对精度」**（`depthDataAccuracy == .relative`），算出来的绝对虚化量不精确。可以把 `virtualFocalLength` 当成「虚化强度」来调。
- **单摄机型**：没有硬件深度。可以换成 Core ML 的单目深度模型（比如 Depth Anything、Apple 的 Depth Pro）来输出视差图，后面的流程完全一样。
- 处理时统一转成 sRGB，HEIC 照片的 P3 广色域会丢失；前置原深感摄像头没有接入（它的方向和镜像需要另外处理）。
