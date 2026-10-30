import Foundation
import BokehCore

// 用法：
//   bokeh-cli <输入.ppm> <视差.pfm> <输出.ppm> [--f 2.8] [--focus 0.5,0.5] [--focal 52] [--refine] [--preview]
//
// 输入图像是 8 位 PPM（P6），视差图是单通道 PFM（Pf，单位 1/米）。
// 视差图尺寸可以和图像不同，加 --refine 会先做补洞、上采样和引导滤波。

func readPPM(_ path: String) throws -> PlanarImage {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var idx = 0
    func token() -> String {
        var s = ""
        while idx < data.count {
            let c = data[idx]
            if c == UInt8(ascii: "#") { while idx < data.count && data[idx] != 10 { idx += 1 }; continue }
            if c == 32 || c == 10 || c == 13 || c == 9 { if !s.isEmpty { break }; idx += 1; continue }
            s.append(Character(UnicodeScalar(c))); idx += 1
        }
        return s
    }
    guard token() == "P6" else { throw NSError(domain: "ppm", code: 1) }
    let w = Int(token())!, h = Int(token())!
    _ = token()
    idx += 1
    return data.withUnsafeBytes { raw in
        PlanarImage(interleaved8: raw.baseAddress! + idx, width: w, height: h, bytesPerRow: w * 3, layout: .rgb)
    }
}

func readPFM(_ path: String) throws -> FloatMap {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var lines: [String] = []
    var idx = 0
    while lines.count < 3 {
        var s = ""
        while data[idx] != 10 { s.append(Character(UnicodeScalar(data[idx]))); idx += 1 }
        idx += 1
        lines.append(s.trimmingCharacters(in: .whitespaces))
    }
    guard lines[0] == "Pf" else { throw NSError(domain: "pfm", code: 1) }
    let dims = lines[1].split(separator: " ").map { Int($0)! }
    let w = dims[0], h = dims[1]
    var values = [Float](repeating: 0, count: w * h)
    data.withUnsafeBytes { raw in
        let base = raw.baseAddress! + idx
        for y in 0..<h {
            // PFM 按从下到上存行
            for x in 0..<w {
                let bits = base.loadUnaligned(fromByteOffset: ((h - 1 - y) * w + x) * 4, as: UInt32.self)
                values[y * w + x] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }
    return FloatMap(width: w, height: h, values: values)
}

func writePFM(_ m: FloatMap, _ path: String) throws {
    var out = Data("Pf\n\(m.width) \(m.height)\n-1.0\n".utf8)
    for y in stride(from: m.height - 1, through: 0, by: -1) {
        for x in 0..<m.width {
            var v = m.values[y * m.width + x].bitPattern.littleEndian
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
    }
    try out.write(to: URL(fileURLWithPath: path))
}

func writePPM(_ img: PlanarImage, _ path: String) throws {
    var out = Data("P6\n\(img.width) \(img.height)\n255\n".utf8)
    let rgba = img.interleavedRGBA8()
    var rgb = [UInt8](repeating: 0, count: img.pixelCount * 3)
    for i in 0..<img.pixelCount {
        rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
    }
    out.append(contentsOf: rgb)
    try out.write(to: URL(fileURLWithPath: path))
}

var args = Array(CommandLine.arguments.dropFirst())

/// 读 PPM 的原始 RGB 字节（模拟相机帧，交给 PlanarImage.cameraFrame 裁切缩放，和 App 里同一份代码）
func readPPMBytes(_ path: String) throws -> (bytes: [UInt8], width: Int, height: Int) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var idx = 0
    func token() -> String {
        var s = ""
        while idx < data.count {
            let c = data[idx]
            if c == UInt8(ascii: "#") { while idx < data.count && data[idx] != 10 { idx += 1 }; continue }
            if c == 32 || c == 10 || c == 13 || c == 9 { if !s.isEmpty { break }; idx += 1; continue }
            s.append(Character(UnicodeScalar(c))); idx += 1
        }
        return s
    }
    guard token() == "P6" else { throw NSError(domain: "ppm", code: 1) }
    let w = Int(token())!, h = Int(token())!
    _ = token()
    idx += 1
    return (Array(data[idx..<(idx + w * h * 3)]), w, h)
}

// 实时预览模拟：bokeh-cli --live -
// 每行一个 JSON：{"img": 相机整帧.ppm, "depth": 整帧视差.pfm 或 "", "out": 输出.ppm, "f": 1.4, "crop": 1.0,
//               "rel": false, "fx": 0.5, "fy": 0.5, "tap": false, "t": 秒, "reset": false, "mask": 人像遮罩.pfm 或 "",
//               "maskimg": 算遮罩那一帧的画面.ppm 或 "", "age": 深度是几帧之前的, "mindist": 米,
//               "objects": 物体分割标签图.pfm 或 "", "objimg": 算物体分割那一帧的画面.ppm 或 "", "long": 1440,
//               "fl": 画面的 35mm 等效焦距（毫米，含裁切；4× 长焦是 100），不填 = 按 1× 的标定,
//               "lock": 锁定对焦（点按后 0.4 秒固定对焦距离）}
// 和 App 的 DepthCameraController 走同一个 LivePreviewPipeline。每帧输出一行 JSON（对焦、耗时）
if args.first == "--live" {
    args.removeFirst()
    let pipeline = LivePreviewPipeline()
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let t0 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if job["reset"] as? Bool == true { pipeline.resetHistory() }
        if let g = job["grow"] as? Double { pipeline.settings.matte.colorGrowth = Float(g) }
        if let g = job["growabs"] as? Double { pipeline.settings.matte.absoluteColorGrowth = Float(g) }
        if let m = job["motion"] as? Double { pipeline.temporal.motionCutoff = Float(m) }
        if let v = job["tstrength"] as? Double { pipeline.temporal.strength = Float(v) }
        if let v = job["bstrength"] as? Double { pipeline.temporal.backgroundStrength = Float(v) }
        if let v = job["hold"] as? Double { pipeline.maxHoldOverride = v }
        let frame = try readPPMBytes(job["img"] as! String)
        let crop = Float(job["crop"] as? Double ?? 1)
        let longSide = job["long"] as? Int ?? 1440
        let image = frame.bytes.withUnsafeBytes { raw in
            PlanarImage.cameraFrame(interleaved8: raw.baseAddress!, width: frame.width, height: frame.height,
                                    bytesPerRow: frame.width * 3, layout: .rgb, longSide: longSide, crop: crop)
        }
        let t1 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let depthPath = job["depth"] as? String ?? ""
        let disparity = depthPath.isEmpty ? nil : try readPFM(depthPath)
        let maskPath = job["mask"] as? String ?? ""
        let mask = maskPath.isEmpty ? nil : try readPFM(maskPath)
        // 算遮罩那一帧的画面（整帧 ppm，任意尺寸，sRGB 8 位）
        let maskImgPath = job["maskimg"] as? String ?? ""
        var maskColors: PlanarImage?
        if !maskImgPath.isEmpty {
            let m = try readPPMBytes(maskImgPath)
            maskColors = m.bytes.withUnsafeBytes { raw in
                PlanarImage.cameraFrame(interleaved8: raw.baseAddress!, width: m.width, height: m.height,
                                        bytesPerRow: m.width * 3, layout: .rgb, longSide: max(m.width, m.height), crop: 1)
            }
        }
        if let v = job["mindist"] as? Double { pipeline.settings.minSubjectDistance = Float(v) }
        let objectsPath = job["objects"] as? String ?? ""
        let objects = objectsPath.isEmpty ? nil : try readPFM(objectsPath)
        // 算物体分割那一帧的画面（整帧 ppm，任意尺寸）
        let objImgPath = job["objimg"] as? String ?? ""
        var objectColors: PlanarImage?
        if !objImgPath.isEmpty {
            let m = try readPPMBytes(objImgPath)
            objectColors = m.bytes.withUnsafeBytes { raw in
                PlanarImage.cameraFrame(interleaved8: raw.baseAddress!, width: m.width, height: m.height,
                                        bytesPerRow: m.width * 3, layout: .rgb, longSide: max(m.width, m.height), crop: 1)
            }
        }
        let input = LivePreviewPipeline.Frame(
            image: image, disparity: disparity, relativeDepth: job["rel"] as? Bool ?? false, crop: crop,
            fNumber: Float(job["f"] as? Double ?? 2.8),
            focusPoint: (Float(job["fx"] as? Double ?? 0.5), Float(job["fy"] as? Double ?? 0.5)),
            focusTapped: job["tap"] as? Bool ?? false, time: job["t"] as? Double ?? 0, personMask: mask,
            personMaskColors: maskColors, depthAge: job["age"] as? Int ?? 0,
            objectLabels: objects, objectColors: objectColors, objectRevision: job["objrev"] as? Int ?? 0,
            focalLength35mm: (job["fl"] as? Double).map { Float($0) }, focusLocked: job["lock"] as? Bool ?? false)
        let dbg = job["dbg"] as? String ?? ""
        pipeline.renderer.captureDebugMaps = !dbg.isEmpty
        let r = pipeline.process(input)
        let t2 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if !dbg.isEmpty {
            if let m = pipeline.renderer.debugRefinedDisparity { try writePFM(m, dbg + "_refined.pfm") }
            if let m = pipeline.renderer.debugLowDisparity { try writePFM(m, dbg + "_final.pfm") }
            if let m = pipeline.temporal.debugUnreliable { try writePFM(m, dbg + "_u.pfm") }
            if let m = pipeline.renderer.debugMatte { try writePFM(m, dbg + "_matte.pfm") }
            if let m = pipeline.renderer.debugWeights { try writePFM(m, dbg + "_w.pfm") }
        }
        if let out = job["out"] as? String, !out.isEmpty { try writePPM(r.image, out) }
        var info: [String: Any] = ["out": job["out"] as? String ?? "", "w": r.image.width, "h": r.image.height,
                                   "fx": r.focusPoint.x, "fy": r.focusPoint.y, "recentered": r.focusRecentered,
                                   "tooClose": r.tooClose, "moving": r.cameraMoving,
                                   "shift": pipeline.lastPlan?.cameraShift ?? 0,
                                   "ms_frame": (t1 - t0) * 1000, "ms_pipeline": (t2 - t1) * 1000]
        if let v = pipeline.lastPlan?.personMaskStale { info["personStale"] = v }
        if let v = pipeline.lastPlan?.objectMaskStale { info["objectStale"] = v }
        if let d = r.focusDisparity { info["focusD"] = d }
        if let d = r.focusDistance { info["focusM"] = d }
        for (k, v) in r.timings { info["ms_" + k] = v }
        let json = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
        fflush(stdout)
    }
    exit(0)
}

// 批处理：bokeh-cli --batch jobs.txt [--temporal] [其它参数]
// jobs.txt 每行：输入.ppm 视差.pfm 输出.ppm ƒ值 对焦视差。同一个进程按顺序渲染，模拟 App 里的连续预览
if args.first == "--batch" {
    args.removeFirst()
    let jobsPath = args.removeFirst()
    var useTemporal = false, low = 480, tol: Float = 0.06, soft: Float = 0.012, focalB: Float = 52
    var thinB = false, matteB = false
    var qualityB = RenderQuality.preview
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--temporal": useTemporal = true
        case "--thin": thinB = true
        case "--matte": matteB = true
        case "--legacy-highlights": qualityB.useLegacyHighlights()
        case "--hgain": qualityB.highlightGain = Float(args.removeFirst())!
        case "--hthr": qualityB.highlightThreshold = Float(args.removeFirst())!
        case "--lowres": low = Int(args.removeFirst())!
        case "--tol": tol = Float(args.removeFirst())!
        case "--soft": soft = Float(args.removeFirst())!
        case "--focal": focalB = Float(args.removeFirst())!
        case "--photo": qualityB = .photo
        case "--preview": qualityB = .preview
        default: print("未知参数 \(a)"); exit(1)
        }
    }
    let renderer = BokehRenderer()
    let temporal: TemporalState? = useTemporal ? TemporalState() : nil
    var total: Double = 0, count = 0
    // jobs 文件路径为 "-" 时从标准输入逐行读（边解码边渲染）
    var lines: [String] = []
    if jobsPath != "-" { lines = try String(contentsOfFile: jobsPath, encoding: .utf8).split(separator: "\n").map(String.init) }
    var li = 0
    func nextLine() -> String? {
        if jobsPath == "-" { return readLine() }
        defer { li += 1 }
        return li < lines.count ? lines[li] : nil
    }
    while let line = nextLine() {
        let p = line.split(separator: " ").map(String.init)
        guard p.count >= 5 else { continue }
        let image = try readPPM(p[0])
        let disparity = try readPFM(p[1])
        let lens = LensParameters(fNumber: Float(p[3])!, focusDisparity: Float(p[4])!, model: thinB ? .thinLens : .system,
                                  focalLength35mm: focalB, focusTolerance: thinB && tol == 0.06 ? 0.08 : tol,
                                  softLimitFraction: soft)
        var hint: SubjectHint? = nil
        if matteB { hint = SubjectHint(point: p.count >= 7 ? (Float(p[5])!, Float(p[6])!) : nil) }
        let t0 = Date()
        let out = renderer.renderDetailPreserving(full: image, disparity: disparity, lens: lens, lowLongSide: low,
                                                  quality: qualityB, temporal: temporal, subject: hint)
        total += Date().timeIntervalSince(t0) * 1000; count += 1
        try writePPM(out, p[2])
        print("done \(p[2])")
        fflush(stdout)
    }
    print(String(format: "平均渲染 %.1fms（%d 帧）", total / Double(max(1, count)), count))
    exit(0)
}

guard args.count >= 3 else {
    print("用法: bokeh-cli in.ppm disparity.pfm out.ppm [--f 2.8] [--focus x,y] [--focal 52] [--refine] [--preview]")
    exit(1)
}
let inPath = args.removeFirst(), dispPath = args.removeFirst(), outPath = args.removeFirst()
var fNumber: Float = 2.8, focus: (Float, Float) = (0.5, 0.5), focal: Float = 52
var refine = false, quality = RenderQuality.photo
var focusDisparityOverride: Float? = nil
var saveRefined: String? = nil
var lowres = 0
var tolerance: Float = 0.06
var softLimit: Float = 0.012
var thin = false, useMatte = false
var debugPrefix: String? = nil
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--f": fNumber = Float(args.removeFirst())!
    case "--focal": focal = Float(args.removeFirst())!
    case "--focus":
        let p = args.removeFirst().split(separator: ",").map { Float($0)! }
        focus = (p[0], p[1])
    case "--refine": refine = true
    case "--preview": quality = .preview
    case "--focus-disp": focusDisparityOverride = Float(args.removeFirst())!
    case "--save-refined": saveRefined = args.removeFirst()
    case "--lowres": lowres = Int(args.removeFirst())!
    case "--tol": tolerance = Float(args.removeFirst())!
    case "--soft": softLimit = Float(args.removeFirst())!
    case "--thin": thin = true
    case "--matte": useMatte = true
    case "--debug": debugPrefix = args.removeFirst()
    case "--hgain": quality.highlightGain = Float(args.removeFirst())!
    default: print("未知参数 \(a)"); exit(1)
    }
}

let image = try readPPM(inPath)
var disparity = try readPFM(dispPath)
let renderer = BokehRenderer()
renderer.captureDebugMaps = debugPrefix != nil
let t0 = Date()
var result: PlanarImage
var focusD: Float
if lowres > 0 {
    // 双分辨率：模糊在低分辨率算，清晰部分用全分辨率
    focusD = focusDisparityOverride ?? DepthRefiner.focusDisparity(in: DepthRefiner.fillInvalid(disparity), nx: focus.0, ny: focus.1)
    let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, model: thin ? .thinLens : .system,
                              focalLength35mm: focal, focusTolerance: thin && tolerance == 0.06 ? 0.08 : tolerance,
                              softLimitFraction: softLimit)
    result = renderer.renderDetailPreserving(full: image, disparity: disparity, lens: lens, lowLongSide: lowres, quality: quality,
                                             subject: useMatte ? SubjectHint(point: focus) : nil)
} else {
    if refine || disparity.width != image.width || disparity.height != image.height {
        disparity = DepthRefiner.refine(disparity: disparity, guide: image)
    }
    focusD = focusDisparityOverride ?? DepthRefiner.focusDisparity(in: disparity, nx: focus.0, ny: focus.1)
    if let path = saveRefined { try writePFM(disparity, path) }
    let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, model: thin ? .thinLens : .system,
                              focalLength35mm: focal, focusTolerance: thin && tolerance == 0.06 ? 0.08 : tolerance,
                              softLimitFraction: softLimit)
    result = renderer.render(image: image, disparity: disparity, lens: lens, quality: quality)
}
let total = Date().timeIntervalSince(t0) * 1000
try writePPM(result, outPath)
if let p = debugPrefix {
    if let w = renderer.debugWeights { try writePFM(w, p + "_w.pfm") }
    if let d = renderer.debugLowDisparity { try writePFM(d, p + "_dlow.pfm") }
    if let m = renderer.debugMatte { try writePFM(m, p + "_matte.pfm") }
}
print(String(format: "%dx%d  ƒ%.1f  对焦视差 %.3f (%.2fm)  层数 %d  深度处理 0ms  渲染 %.0fms",
             image.width, image.height, fNumber, focusD, 1 / focusD, renderer.lastLayerCount, total))
