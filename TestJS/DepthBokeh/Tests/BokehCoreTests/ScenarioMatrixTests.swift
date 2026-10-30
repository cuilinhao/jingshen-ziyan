import XCTest
@testable import BokehCore

/// 场景矩阵：同一批合成场景 × 深度来源（LiDAR / 双摄相对视差 / AI 单目）× 焦段 × 对焦位置，
/// 走和 App 一样的 LivePreviewPipeline（分析 + 主体遮罩 + 渲染），读出每块区域最终的虚化半径，
/// 和「理想」（同一个镜头模型、真实视差、对焦的主体整个清晰）比。
///
/// 为什么要有它：很多参数是在某一种条件下定的（1×、LiDAR、近距离），换个焦段 / 深度来源 / 对焦距离就悄悄失效，
/// 只测当时报的那一个场景发现不了。改镜头模型、主体遮罩、分析里的任何东西以后跑一遍（Debug 下太慢，会跳过）：
///     swift test -c release --filter ScenarioMatrixTests              // 打印整张表，有问题的组合标 ✗
///     NOISE=0.04 swift test -c release --filter ScenarioMatrixTests   // 深度噪声加大 10 倍再跑
///     RAMP=1 …                                                        // 另外打印桌面逐行的虚化量
/// 以后遇到新的问题场景，照着下面的 Scene 加一个（距离按米，标明是人 / 物体 / 其他），放进 cases。
///
/// 判断规则（虚化半径都按长边的百分比）：
///  - 主体（对焦那一层，以及同一个人 / 物体的其他部分）：中位数超过 0.15% 算「主体糊了」；
///    主体和后面东西交界的那一圈，80% 分位超过 0.3% 算「主体边缘糊」
///  - 其他东西：理想虚化 ≥ 0.4%（1440 宽约 6 像素，明显看得出）却不到一半 →「该糊没糊」；
///    理想 < 0.1% 却超过 0.35% →「不该糊糊了」
///  - 过渡（有 ramp 的场景）：跨一个深度像素，虚化量的变化比理想多出 0.2% 以上 →「硬过渡」
///  - AI 单目深度每帧归一化，单位不是 1/米，只查「明显该糊（≥ 0.5%）却几乎没糊（< 0.1%）」
final class ScenarioMatrixTests: XCTestCase {

    enum Kind: Equatable { case stuff, person(Int), object(Int) }

    struct Layer {
        var name: String
        var kind: Kind
        var color: (Float, Float, Float)
        /// 归一化坐标 → 这一点的距离（米），nil = 不在这一层
        var shape: (Float, Float) -> Float?
        /// 深度图在这一层测出来的距离（米）；nil = 测得准。模拟深度测错：伸出脸外的眼镜框测到的是后面背景，
        /// 人旁边一圈背景测到的是人
        var measured: Float? = nil
        /// 细条（眼镜框、光晕）：取样时不往里缩
        var thin = false
        /// 这一层多少像素没有深度（NaN，成块出现）。双摄在没纹理的地方（白墙、显示器屏幕）测不出视差；
        /// 长焦不用系统滤波以后，这些洞由分析里的 DepthRefiner.fillInvalid 补
        var holes: Float = 0
    }

    struct Scene {
        var name: String
        var layers: [Layer]   // 后画的盖住先画的
        /// 检查过渡的区域（x0, x1, y0, y1）：沿 y 方向逐行看虚化量，不能比理想的突然跳一大截（硬过渡）
        var ramp: (Float, Float, Float, Float)? = nil
    }

    enum Source: CustomStringConvertible {
        case lidar, dual(Float), mono
        var description: String {
            switch self {
            case .lidar: return "LiDAR"
            case .dual(let o): return String(format: "双摄+%.1f", o)
            case .mono: return "AI"
            }
        }
        var relative: Bool { if case .lidar = self { return false } else { return true } }
    }

    static func rect(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, _ z: Float) -> (Float, Float) -> Float? {
        { x, y in x >= x0 && x < x1 && y >= y0 && y < y1 ? z : nil }
    }
    static func ellipse(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, _ z: Float) -> (Float, Float) -> Float? {
        { x, y in let u = (x - cx) / rx, v = (y - cy) / ry; return u * u + v * v < 1 ? z : nil }
    }

    struct Rendered {
        var label: [Int]          // 每个深度像素属于哪一层
        var trueDisparity: [Float]
        var w: Int, h: Int
    }

    struct Outcome {
        var line: String
        var failures: [String]
    }

    /// 跑一个组合，返回每层的结果
    static func run(_ scene: Scene, source: Source, focal: Float, focusLayer: String, focusPoint: (Float, Float),
                    fNumber: Float = 1.4, instances: Bool = true, verbose: Bool = false) -> Outcome {
        let w = 160, h = 120, iw = 640, ih = 480
        var label = [Int](repeating: -1, count: w * h)
        var z = [Float](repeating: 10, count: w * h)
        var zm = z
        for y in 0..<h {
            for x in 0..<w {
                let nx = (Float(x) + 0.5) / Float(w), ny = (Float(y) + 0.5) / Float(h)
                for (k, l) in scene.layers.enumerated() {
                    if let v = l.shape(nx, ny) { label[y * w + x] = k; z[y * w + x] = v; zm[y * w + x] = l.measured ?? v }
                }
            }
        }
        // 图像（640×480，平涂颜色 + 一点纹理）
        var r = [Float](repeating: 0, count: iw * ih), g = r, b = r
        for y in 0..<ih {
            for x in 0..<iw {
                let nx = (Float(x) + 0.5) / Float(iw), ny = (Float(y) + 0.5) / Float(ih)
                var c: (Float, Float, Float) = (0.5, 0.5, 0.5)
                for l in scene.layers where l.shape(nx, ny) != nil { c = l.color }
                let t = 0.03 * sinf(Float(x) * 0.7) * sinf(Float(y) * 0.9)
                r[y * iw + x] = max(0, c.0 + t); g[y * iw + x] = max(0, c.1 + t); b[y * iw + x] = max(0, c.2 + t)
            }
        }
        let image = PlanarImage(width: iw, height: ih, r: r, g: g, b: b)
        // 深度：真实视差 → 深度来源 → 边缘被滤波抹开（双摄更宽）+ 一点噪声
        let truth = z.map { 1 / $0 }
        var d = zm.map { 1 / $0 }
        switch source {
        case .lidar: break
        case .dual(let off): d = d.map { $0 + off }
        case .mono:
            let s = d.sorted()
            let lo = s[s.count * 2 / 100], hi = s[s.count * 98 / 100]
            d = d.map { min(max(($0 - lo) / max(hi - lo, 1e-6), 0), 1.5) + 0.02 }
        }
        let smear: Int
        switch source { case .lidar: smear = 1; case .dual: smear = 2; case .mono: smear = 2 }
        d = boxBlur(d, w: w, h: h, r: smear)
        // 噪声：低频（块状，深度图常见）+ 逐像素。幅度由环境变量 NOISE 控制（视差单位，默认 0.004）
        let amp = Float(ProcessInfo.processInfo.environment["NOISE"] ?? "") ?? 0.004
        func hash(_ i: Int) -> Float { let v = sinf(Float(i) * 12.9898 + 78.233) * 43758.5453; return (v - floorf(v)) * 2 - 1 }
        for y in 0..<h {
            for x in 0..<w {
                let blk = hash((y / 6) * 1000 + x / 6 + 7)
                d[y * w + x] += amp * (0.6 * blk + 0.4 * hash(y * w + x))
            }
        }
        // 双摄没有深度的地方（4×4 一块，按这一层的 holes 比例）。激光雷达走系统滤波、AI 每个像素都有值，不挖洞
        if case .dual = source {
            for y in 0..<h {
                for x in 0..<w where label[y * w + x] >= 0 {
                    let holes = scene.layers[label[y * w + x]].holes
                    if holes > 0, (hash((y / 4) * 977 + x / 4 + 31) + 1) / 2 < holes { d[y * w + x] = .nan }
                }
            }
        }
        let disparity = FloatMap(width: w, height: h, values: d)
        // 人像遮罩 / 实例 / 物体标签
        var person = [Float](repeating: 0, count: w * h), inst = person, obj = person
        var hasPerson = false, hasObj = false
        for i in 0..<(w * h) where label[i] >= 0 {
            switch scene.layers[label[i]].kind {
            // Vision 的人像实例最多 4 个人：编号 5 以后的人只在人像遮罩里
            case .person(let id): person[i] = 1; inst[i] = id <= 4 ? Float(id) : 0; hasPerson = true
            case .object(let id): obj[i] = Float(id); hasObj = true
            case .stuff: break
            }
        }
        let pipeline = LivePreviewPipeline()
        pipeline.renderer.captureDebugMaps = true
        for t in 0..<8 {
            _ = pipeline.process(LivePreviewPipeline.Frame(
                image: image, disparity: disparity, relativeDepth: source.relative, crop: 1, fNumber: fNumber,
                focusPoint: focusPoint, focusTapped: t == 0, time: Double(t) / 30,
                personMask: hasPerson ? FloatMap(width: w, height: h, values: person) : nil,
                objectLabels: hasObj ? FloatMap(width: w, height: h, values: obj) : nil,
                personInstances: hasPerson && instances ? FloatMap(width: w, height: h, values: inst) : nil,
                focalLength35mm: focal))
        }
        guard let plan = pipeline.lastPlan, let final = pipeline.renderer.debugLowDisparity else {
            return Outcome(line: "no plan", failures: ["no plan"])
        }
        // 理想：同一个镜头模型，真实视差，对焦那一层整个清晰
        let fi = scene.layers.firstIndex { $0.name == focusLayer }!
        // 主体：对焦那一层，以及同一个人 / 同一个物体的其他部分（手腕和拳头是同一个人）
        let fk = scene.layers[fi].kind
        let subject = Set(scene.layers.indices.filter { $0 == fi || (fk != .stuff && scene.layers[$0].kind == fk) })
        var zf: [Float] = []
        for i in 0..<(w * h) where label[i] == fi { zf.append(z[i]) }
        zf.sort()
        var ideal = LensParameters(fNumber: fNumber, focusDisparity: 1 / zf[zf.count / 2])
        ideal.scaleForFocalLength(focal)
        let lw = final.width, lh = final.height
        let L: Float = 1000
        var parts: [String] = []
        var failures: [String] = []
        for (k, l) in scene.layers.enumerated() {
            // 低分辨率上这一层的像素（往里缩 2 个深度像素，避开边缘）
            var act: [Float] = [], tru: [Float] = []
            for y in 0..<lh {
                for x in 0..<lw {
                    let sx = min(w - 1, Int((Float(x) + 0.5) / Float(lw) * Float(w)))
                    let sy = min(h - 1, Int((Float(y) + 0.5) / Float(lh) * Float(h)))
                    var inside = label[sy * w + sx] == k
                    let er = l.thin ? 0 : 2
                    for yy in max(0, sy - er)...min(h - 1, sy + er) where inside {
                        for xx in max(0, sx - er)...min(w - 1, sx + er) where label[yy * w + xx] != k { inside = false; break }
                    }
                    guard inside else { continue }
                    act.append(plan.lens.signedBlurRadius(disparity: final[x, y], imageLongSide: Int(L)) / L * 100)
                    tru.append(subject.contains(k) ? 0 : ideal.signedBlurRadius(disparity: truth[sy * w + sx], imageLongSide: Int(L)) / L * 100)
                }
            }
            guard !act.isEmpty else { continue }
            act.sort(); tru.sort()
            let a = act[act.count / 2], e = tru[tru.count / 2]
            var flag = ""
            if subject.contains(k) {
                if abs(a) > 0.15 { flag = "✗主体糊了" }
            } else if case .mono = source {
                if abs(e) >= 0.5 && abs(a) < 0.1 { flag = "✗该糊没糊" }
            } else {
                if abs(e) >= 0.4 && abs(a) < 0.5 * abs(e) { flag = "✗该糊没糊" }
                else if abs(e) < 0.1 && abs(a) > 0.35 { flag = "✗不该糊糊了" }
            }
            parts.append(String(format: "%@ %+.2f(应%+.2f)%@", l.name, a, e, flag))
            if !flag.isEmpty { failures.append("\(l.name)\(flag)") }
        }
        // 主体边缘一圈（深度被抹开的地方）：80% 分位的虚化量
        var ring: [Float] = []
        for y in 0..<lh {
            for x in 0..<lw {
                let sx = min(w - 1, Int((Float(x) + 0.5) / Float(lw) * Float(w)))
                let sy = min(h - 1, Int((Float(y) + 0.5) / Float(lh) * Float(h)))
                guard subject.contains(label[sy * w + sx]) else { continue }
                var edge = false
                for yy in max(0, sy - 2)...min(h - 1, sy + 2) where !edge {
                    // 只看主体和后面的东西交界的地方（挨着前景的边被前景的虚化盖住，本来就该糊）
                    for xx in max(0, sx - 2)...min(w - 1, sx + 2)
                    where !subject.contains(label[yy * w + xx]) && z[yy * w + xx] > z[sy * w + sx] { edge = true; break }
                }
                if edge { ring.append(abs(plan.lens.signedBlurRadius(disparity: final[x, y], imageLongSide: Int(L)) / L * 100)) }
            }
        }
        if !ring.isEmpty {
            ring.sort()
            let e80 = ring[ring.count * 8 / 10]
            let flag = e80 > 0.3 ? "✗主体边缘糊" : ""
            parts.append(String(format: "[边缘%.2f%@]", e80, flag))
            if !flag.isEmpty { failures.append("主体边缘" + flag) }
        }
        // 过渡：沿 ramp 逐行（低分辨率）取虚化量中位数，相邻两行的跳变和理想的比
        if let (x0, x1, y0, y1) = scene.ramp {
            var rowsA: [Float] = [], rowsE: [Float] = []
            for y in Int(y0 * Float(lh))..<Int(y1 * Float(lh)) {
                var a: [Float] = [], e: [Float] = []
                for x in Int(x0 * Float(lw))..<Int(x1 * Float(lw)) {
                    let sx = min(w - 1, Int((Float(x) + 0.5) / Float(lw) * Float(w)))
                    let sy = min(h - 1, Int((Float(y) + 0.5) / Float(lh) * Float(h)))
                    a.append(plan.lens.signedBlurRadius(disparity: final[x, y], imageLongSide: Int(L)) / L * 100)
                    e.append(ideal.signedBlurRadius(disparity: truth[sy * w + sx], imageLongSide: Int(L)) / L * 100)
                }
                a.sort(); e.sort()
                rowsA.append(a[a.count / 2]); rowsE.append(e[e.count / 2])
            }
            if ProcessInfo.processInfo.environment["RAMP"] != nil {
                print("ramp actual: " + rowsA.map { String(format: "%.2f", $0) }.joined(separator: " "))
                print("ramp ideal : " + rowsE.map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            // 跨一个深度像素（低分辨率 3 行左右）比：理想值是按深度图像素取的，本身就是每 3 行一个台阶
            let span = max(1, Int((Float(lh) / Float(h)).rounded()))
            var worst: Float = 0
            for k in span..<rowsA.count {
                worst = max(worst, abs(rowsA[k] - rowsA[k - span]) - abs(rowsE[k] - rowsE[k - span]))
            }
            let flag = worst > 0.2 ? "✗硬过渡" : ""
            parts.append(String(format: "[过渡跳变%.2f%@]", worst, flag))
            if !flag.isEmpty { failures.append("过渡" + flag) }
        }
        let line = String(format: "%-12@ %3.0fmm 对焦%@%@ | ", source.description, focal, focusLayer,
                          instances ? "" : "(无实例)") + parts.joined(separator: "  ")
        if verbose { print(line) }
        return Outcome(line: line, failures: failures)
    }

    static func boxBlur(_ v: [Float], w: Int, h: Int, r: Int) -> [Float] {
        guard r > 0 else { return v }
        var out = v
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, n: Float = 0
                for yy in max(0, y - r)...min(h - 1, y + r) { for xx in max(0, x - r)...min(w - 1, x + r) { s += v[yy * w + xx]; n += 1 } }
                out[y * w + x] = s / n
            }
        }
        return out
    }

    // MARK: 场景

    static let wall: (Float, Float, Float) = (0.55, 0.55, 0.5)

    /// 用户录屏：远处的 A（3.75 m）、近处背对镜头的 B（2.3 m）和椅背（2.1 m），A 前面的隔板，8 m 外的墙
    static let officeAB = Scene(name: "办公室AB", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 8)),
        Layer(name: "隔板", kind: .stuff, color: (0.8, 0.8, 0.75), shape: rect(0, 0.45, 0.55, 1, 3.3)),
        Layer(name: "A", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.15, 0.40, 0.25, 0.60, 3.75)),
        Layer(name: "B", kind: .person(2), color: (0.08, 0.08, 0.1), shape: rect(0.40, 0.80, 0.30, 1, 2.3)),
        Layer(name: "椅背", kind: .stuff, color: (0.85, 0.85, 0.82), shape: rect(0.45, 0.75, 0.55, 1, 2.1)),
    ])

    /// 人站在墙前 0.6 m
    static let personWall = Scene(name: "人墙", layers: [
        Layer(name: "墙", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 2.6)),
        Layer(name: "人", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.35, 0.65, 0.2, 1, 2.0)),
    ])

    /// 桌面从画面底部 0.8 m 斜着延伸到中间 4 m，桌上 2 m 处一个杯子，后面 5 m 的墙
    static let desk = Scene(name: "桌面", layers: [
        Layer(name: "墙", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 5)),
        Layer(name: "桌近", kind: .stuff, color: (0.6, 0.45, 0.3), shape: { x, y in y >= 0.8 ? 1 / (1 / 0.8 * (y - 0.5) / 0.5 + 1 / 4.0 * (1 - (y - 0.5) / 0.5)) : nil }),
        Layer(name: "桌中", kind: .stuff, color: (0.6, 0.45, 0.3), shape: { x, y in y >= 0.62 && y < 0.8 ? 1 / (1 / 0.8 * (y - 0.5) / 0.5 + 1 / 4.0 * (1 - (y - 0.5) / 0.5)) : nil }),
        Layer(name: "桌远", kind: .stuff, color: (0.6, 0.45, 0.3), shape: { x, y in y >= 0.5 && y < 0.62 ? 1 / (1 / 0.8 * (y - 0.5) / 0.5 + 1 / 4.0 * (1 - (y - 0.5) / 0.5)) : nil }),
        Layer(name: "杯子", kind: .object(1), color: (0.9, 0.9, 0.95), shape: rect(0.45, 0.55, 0.52, 0.72, 2.0)),
    ], ramp: (0.1, 0.4, 0.5, 1))

    /// 拳头 0.46 m（手腕 0.52 m），背景 3 m
    static let fist = Scene(name: "拳头", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 3)),
        Layer(name: "手腕", kind: .person(1), color: (0.75, 0.55, 0.45), shape: rect(0.45, 0.6, 0.6, 1, 0.52)),
        Layer(name: "拳头", kind: .person(1), color: (0.78, 0.58, 0.47), shape: ellipse(0.52, 0.5, 0.12, 0.16, 0.46)),
    ])

    /// 并排两个人，2.0 m 和 2.15 m，背景 4 m
    static let sideBySide = Scene(name: "并排", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 4)),
        Layer(name: "左人", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.2, 0.45, 0.2, 1, 2.0)),
        Layer(name: "右人", kind: .person(2), color: (0.3, 0.35, 0.6), shape: rect(0.45, 0.7, 0.25, 1, 2.15)),
    ])

    /// 对焦在 5 m 的墙上，1.5 m 处有个人挡在前面
    static let wallFront = Scene(name: "对焦背景", layers: [
        Layer(name: "墙", kind: .stuff, color: (0.4, 0.55, 0.45), shape: rect(0, 1, 0, 1, 5)),
        Layer(name: "前人", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.55, 0.85, 0.2, 1, 1.5)),
    ])

    /// 近处的人（0.9 m）挡住后面同事（2.5 m），对焦近处
    static let overlap = Scene(name: "前后两人", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 5)),
        Layer(name: "后人", kind: .person(2), color: (0.3, 0.35, 0.6), shape: rect(0.45, 0.75, 0.1, 0.9, 2.5)),
        Layer(name: "近人", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.2, 0.5, 0.3, 1, 0.9)),
    ])

    /// 近处的盒子（正面 0.45 m，顶面斜着往后到 0.6 m），背景 3 m：整个盒子要清晰（以前 4× 顶面有「蒙层」）
    static let box = Scene(name: "盒子", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 3)),
        Layer(name: "盒顶", kind: .object(1), color: (0.85, 0.7, 0.5), shape: { x, y in
            x >= 0.3 && x < 0.7 && y >= 0.35 && y < 0.5 ? 0.6 - (y - 0.35) / 0.15 * 0.15 : nil }),
        Layer(name: "盒正面", kind: .object(1), color: (0.75, 0.6, 0.42), shape: rect(0.3, 0.7, 0.5, 0.85, 0.45)),
    ])

    /// Vision 认不出来的主体（盆栽、杯子没被分割出来）：只能靠深度 + 颜色。1.5 m，背景 3 m
    static let plant = Scene(name: "盆栽", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 3)),
        Layer(name: "花盆", kind: .stuff, color: (0.7, 0.35, 0.2), shape: rect(0.4, 0.6, 0.65, 0.9, 1.5)),
        Layer(name: "叶子", kind: .stuff, color: (0.2, 0.55, 0.2), shape: ellipse(0.5, 0.45, 0.17, 0.22, 1.45)),
    ])

    /// 6 个人：1 m、2 m、2.1 m、3 m、5 m、5 m（远处两个，一个挨着 3 m 的人、一个单独站着），有的在画面上挨着、
    /// 有的被前面的人挡住一部分，背景 8 m。Vision 的人像实例最多编 4 个人，5 m 的两个人只在人像遮罩里
    static let crowd = Scene(name: "多人", layers: [
        Layer(name: "背景", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 8)),
        Layer(name: "远人2", kind: .person(6), color: (0.5, 0.3, 0.5), shape: rect(0.85, 0.95, 0.2, 0.5, 5)),
        Layer(name: "远人", kind: .person(5), color: (0.6, 0.6, 0.3), shape: rect(0.62, 0.72, 0.22, 0.55, 5)),
        Layer(name: "3米", kind: .person(4), color: (0.3, 0.5, 0.6), shape: rect(0.45, 0.63, 0.25, 0.8, 3)),
        Layer(name: "2.1米", kind: .person(3), color: (0.65, 0.4, 0.35), shape: rect(0.30, 0.45, 0.3, 1, 2.1)),
        Layer(name: "2米", kind: .person(2), color: (0.4, 0.45, 0.3), shape: rect(0.18, 0.32, 0.3, 1, 2.0)),
        Layer(name: "1米", kind: .person(1), color: (0.75, 0.55, 0.45), shape: rect(0.0, 0.2, 0.15, 1, 1.0)),
    ])

    /// 深度测错的边：两个人 2.0 m、2.05 m 站在 4 m 的墙前，各有一副伸出脸外的眼镜框，深度图在那儿测到的是墙；
    /// 左边那个人旁边一圈墙反过来测到的是人（光晕）。眼镜要跟着自己的人（这两个人都该清晰），光晕要跟着墙虚化
    static let glasses = Scene(name: "眼镜", layers: [
        Layer(name: "墙", kind: .stuff, color: wall, shape: rect(0, 1, 0, 1, 4)),
        Layer(name: "光晕", kind: .stuff, color: wall, shape: rect(0.235, 0.465, 0.135, 1, 4), measured: 2.0, thin: true),
        Layer(name: "左人", kind: .person(1), color: (0.7, 0.5, 0.4), shape: rect(0.25, 0.45, 0.15, 1, 2.0)),
        Layer(name: "左眼镜", kind: .person(1), color: (0.1, 0.1, 0.12), shape: rect(0.45, 0.51, 0.35, 0.37, 2.0),
              measured: 4, thin: true),
        Layer(name: "右人", kind: .person(2), color: (0.3, 0.35, 0.6), shape: rect(0.62, 0.82, 0.15, 1, 2.05)),
        Layer(name: "右眼镜", kind: .person(2), color: (0.1, 0.1, 0.12), shape: rect(0.56, 0.62, 0.35, 0.37, 2.05),
              measured: 4, thin: true),
    ])

    /// 用户录的 4.2× 现场（rec-20261029-183222）：对焦 5 m 的木棍时，1 m 的柜子（PGYTECH）和 Dell 显示器不该清晰。
    /// 双摄在白墙（9 成）、显示器屏幕（7 成）上没有视差；以前系统滤波把这些洞补成了近处的值，柜子只剩一点虚化。
    /// 这里的洞交给分析自己补，远处的洞要补成远处、近处的洞补成近处
    static let teleDesk = Scene(name: "长焦桌面", layers: [
        Layer(name: "白墙", kind: .stuff, color: (0.85, 0.86, 0.84), shape: rect(0, 1, 0, 1, 6.5), holes: 0.9),
        Layer(name: "墙柜", kind: .stuff, color: (0.92, 0.92, 0.9), shape: rect(0.05, 0.6, 0.05, 0.3, 6), holes: 0.4),
        Layer(name: "木棍", kind: .stuff, color: (0.75, 0.55, 0.3), shape: rect(0.26, 0.33, 0.25, 0.55, 5)),
        Layer(name: "后排", kind: .stuff, color: (0.2, 0.2, 0.22), shape: rect(0.38, 0.52, 0.38, 0.5, 4.5)),
        Layer(name: "柜子", kind: .stuff, color: (0.45, 0.42, 0.4), shape: rect(0.55, 0.9, 0.3, 0.8, 1.05), holes: 0.15),
        Layer(name: "显示器", kind: .stuff, color: (0.6, 0.75, 0.95), shape: rect(0.12, 0.5, 0.6, 0.95, 1.0), holes: 0.7),
    ])

    /// 用户录屏（2×，demo1030 / xitong1030；距离来自 DepthCapture S01_desk 的激光雷达）：对焦 14 m 外的墙，
    /// 6.5 m、4.5 m 两排工位（电脑、桌子），3.4 m 的近处白桌子（和墙颜色接近，颜色补边不能把它拉清晰）。
    /// 以前 2× 前面的全清晰区一直延伸到 5.7 m，工位几乎不糊（LensParameters.toleranceScalingExponent）
    static let farWall = Scene(name: "远墙办公室", layers: [
        Layer(name: "墙", kind: .stuff, color: (0.82, 0.82, 0.8), shape: rect(0, 1, 0, 1, 14)),
        Layer(name: "远工位", kind: .stuff, color: (0.35, 0.36, 0.4), shape: rect(0.1, 0.9, 0.35, 0.5, 6.5)),
        Layer(name: "工位", kind: .stuff, color: (0.2, 0.22, 0.26), shape: rect(0.2, 0.8, 0.5, 0.75, 4.5)),
        Layer(name: "近桌", kind: .stuff, color: (0.88, 0.88, 0.86), shape: rect(0, 1, 0.75, 1, 3.4)),
    ])

    struct Case { var scene: Scene; var focus: String; var point: (Float, Float); var instances = true }

    static let cases: [Case] = [
        Case(scene: officeAB, focus: "A", point: (0.27, 0.42)),
        Case(scene: officeAB, focus: "B", point: (0.6, 0.4)),
        Case(scene: personWall, focus: "人", point: (0.5, 0.5)),
        Case(scene: desk, focus: "杯子", point: (0.5, 0.6)),
        Case(scene: fist, focus: "拳头", point: (0.52, 0.5)),
        Case(scene: sideBySide, focus: "左人", point: (0.3, 0.5)),
        Case(scene: wallFront, focus: "墙", point: (0.25, 0.5)),
        Case(scene: overlap, focus: "近人", point: (0.3, 0.6)),
        Case(scene: box, focus: "盒正面", point: (0.5, 0.65)),
        Case(scene: plant, focus: "叶子", point: (0.5, 0.45)),
        Case(scene: glasses, focus: "左人", point: (0.35, 0.5)),
        Case(scene: glasses, focus: "右人", point: (0.72, 0.5)),
        Case(scene: glasses, focus: "左人", point: (0.35, 0.5), instances: false),
        Case(scene: crowd, focus: "1米", point: (0.1, 0.6)),
        Case(scene: crowd, focus: "2米", point: (0.25, 0.6)),
        Case(scene: crowd, focus: "3米", point: (0.54, 0.4)),
        Case(scene: crowd, focus: "远人", point: (0.67, 0.35)),
        Case(scene: crowd, focus: "1米", point: (0.1, 0.6), instances: false),
        Case(scene: crowd, focus: "2米", point: (0.25, 0.6), instances: false),
        Case(scene: crowd, focus: "3米", point: (0.54, 0.4), instances: false),
        Case(scene: crowd, focus: "远人", point: (0.67, 0.35), instances: false),
        Case(scene: teleDesk, focus: "木棍", point: (0.295, 0.45)),
        Case(scene: teleDesk, focus: "柜子", point: (0.72, 0.5)),
        Case(scene: farWall, focus: "墙", point: (0.5, 0.15)),
    ]

    /// 各深度来源实际出现的焦段（LensCatalog）
    static let combos: [(Source, Float)] = [
        (.lidar, 24), (.lidar, 46),
        (.dual(0.2), 48), (.dual(0.3), 72), (.dual(0.3), 100), (.dual(0.4), 100),
        (.mono, 13),
    ]

    func testMatrix() throws {
        #if DEBUG
        throw XCTSkip("场景矩阵在 Release 下跑：swift test -c release --filter ScenarioMatrixTests")
        #endif
        setvbuf(stdout, nil, _IONBF, 0)
        var total = 0, failed = 0
        var summary: [String] = []
        for c in Self.cases {
            print("\n### \(c.scene.name)，对焦 \(c.focus)\(c.instances ? "" : "（没有人像实例）")")
            for (src, fl) in Self.combos {
                let o = Self.run(c.scene, source: src, focal: fl, focusLayer: c.focus, focusPoint: c.point,
                                 instances: c.instances)
                print(o.line)
                total += 1
                if !o.failures.isEmpty {
                    failed += 1
                    summary.append("\(c.scene.name)/对焦\(c.focus)\(c.instances ? "" : "(无实例)")/\(src)/\(Int(fl))mm: "
                                   + o.failures.joined(separator: "，"))
                }
            }
        }
        print("\n==== \(failed)/\(total) 个组合有问题")
        for s in summary { print("  " + s) }
        XCTAssertTrue(summary.isEmpty, summary.joined(separator: "\n"))
    }
}
