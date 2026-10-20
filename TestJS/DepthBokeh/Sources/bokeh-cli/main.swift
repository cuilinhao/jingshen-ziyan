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

// 批处理：bokeh-cli --batch jobs.txt [--temporal] [其它参数]
// jobs.txt 每行：输入.ppm 视差.pfm 输出.ppm ƒ值 对焦视差。同一个进程按顺序渲染，模拟 App 里的连续预览
if args.first == "--batch" {
    args.removeFirst()
    let jobsPath = args.removeFirst()
    var useTemporal = false, low = 480, tol: Float = 0.08, soft: Float = 0.012, focalB: Float = 52
    var qualityB = RenderQuality.preview
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--temporal": useTemporal = true
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
        let lens = LensParameters(fNumber: Float(p[3])!, focusDisparity: Float(p[4])!, focalLength35mm: focalB,
                                  focusTolerance: tol, softLimitFraction: soft)
        let t0 = Date()
        let out = renderer.renderDetailPreserving(full: image, disparity: disparity, lens: lens, lowLongSide: low,
                                                  quality: qualityB, temporal: temporal)
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
var tolerance: Float = 0.08
var softLimit: Float = 0.012
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
    let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, focalLength35mm: focal, focusTolerance: tolerance, softLimitFraction: softLimit)
    result = renderer.renderDetailPreserving(full: image, disparity: disparity, lens: lens, lowLongSide: lowres, quality: quality)
} else {
    if refine || disparity.width != image.width || disparity.height != image.height {
        disparity = DepthRefiner.refine(disparity: disparity, guide: image)
    }
    focusD = focusDisparityOverride ?? DepthRefiner.focusDisparity(in: disparity, nx: focus.0, ny: focus.1)
    if let path = saveRefined { try writePFM(disparity, path) }
    let lens = LensParameters(fNumber: fNumber, focusDisparity: focusD, focalLength35mm: focal, focusTolerance: tolerance, softLimitFraction: softLimit)
    result = renderer.render(image: image, disparity: disparity, lens: lens, quality: quality)
}
let total = Date().timeIntervalSince(t0) * 1000
try writePPM(result, outPath)
if let p = debugPrefix {
    if let w = renderer.debugWeights { try writePFM(w, p + "_w.pfm") }
    if let d = renderer.debugLowDisparity { try writePFM(d, p + "_dlow.pfm") }
}
print(String(format: "%dx%d  ƒ%.1f  对焦视差 %.3f (%.2fm)  层数 %d  深度处理 0ms  渲染 %.0fms",
             image.width, image.height, fNumber, focusD, 1 / focusD, renderer.lastLayerCount, total))
