import Foundation

/// 按分割修深度边缘：分割只用来告诉「边界在哪」，每一边用自己那一侧可靠的深度。
///
/// 实时深度图分辨率低、边缘被滤波抹开：人的头发、伸出脸外的眼镜框拿到的是后面背景的深度（被当成背景虚化，像蒙了一层）；
/// 人旁边的一圈背景反过来拿到人的深度（背景上留一圈清晰的光晕）。
///
/// 做法（深度图分辨率，CPU 几毫秒）：
///  1. 人像遮罩（所有人，不只是对焦的那个）按连通块分成几块；遮罩外面算「背景」一块
///  2. 分界线两边各 band 个像素以内的深度不可信，其余可信
///  3. 不可信的像素，从同一块里最近的可信像素一圈一圈往外填（取已填好的同块邻居的平均）：
///     头发、眼镜拿到这个人自己的深度，外面那圈光晕拿到旁边背景的深度
///  4. 整块都不可信的细条（比如只有眼镜框的一块）用这一块的中位数
/// 只修边，不决定清不清晰：修完以后糊多少照样只看镜头。对焦的人、旁边一样远的人、远处的人一视同仁。
/// 遮罩是几帧之前算的：画面从那以后变了的地方（valid < 0.5）不修，保持原样。
public enum SegmentEdgeRepair {

    /// - Parameters:
    ///   - depth: 已补洞的视差图（深度图分辨率）
    ///   - segments: 人像遮罩（任意分辨率，0…1，> 0.5 算人）
    ///   - valid: 和 depth 一样大，< 0.5 的地方遮罩不可信（画面变了），不修；nil = 都可信
    ///   - band: 分界线两边各多少像素的深度不可信
    public static func repair(depth: FloatMap, segments: FloatMap, valid: [Float]? = nil, band: Int) -> FloatMap {
        let w = depth.width, h = depth.height, n = w * h
        guard n > 0, band > 0 else { return depth }
        let sm = segments.width == w && segments.height == h ? segments.values
            : segments.resized(width: w, height: h).values
        // 1. 连通块编号（4 连通）：0 = 背景，1… = 各块人像
        var label = [Int32](repeating: 0, count: n)
        var next: Int32 = 0
        var stack = [Int32]()
        stack.reserveCapacity(n / 4)
        sm.withUnsafeBufferPointer { S in
        label.withUnsafeMutableBufferPointer { Lb in
            for s in 0..<n where S[s] > 0.5 && Lb[s] == 0 {
                next += 1
                Lb[s] = next
                stack.append(Int32(s))
                while let top = stack.popLast() {
                    let i = Int(top), x = i % w
                    if x > 0, S[i - 1] > 0.5, Lb[i - 1] == 0 { Lb[i - 1] = next; stack.append(Int32(i - 1)) }
                    if x < w - 1, S[i + 1] > 0.5, Lb[i + 1] == 0 { Lb[i + 1] = next; stack.append(Int32(i + 1)) }
                    if i >= w, S[i - w] > 0.5, Lb[i - w] == 0 { Lb[i - w] = next; stack.append(Int32(i - w)) }
                    if i + w < n, S[i + w] > 0.5, Lb[i + w] == 0 { Lb[i + w] = next; stack.append(Int32(i + w)) }
                }
            }
        }}
        guard next > 0 else { return depth }
        // 2. 分界线两边 band 以内：和另一边的像素距离 ≤ band（方形窗口）。
        //    两块人像直接挨着（两个人连在一起）时没有背景隔开：只按「人 / 背景」的分界修，人和人之间不动
        var isSeg = [Float](repeating: 0, count: n), isBg = [Float](repeating: 1, count: n)
        for i in 0..<n where label[i] > 0 { isSeg[i] = 1; isBg[i] = 0 }
        let nearSeg = SubjectMatte.dilateBinary(isSeg, width: w, height: h, radius: band)
        let nearBg = SubjectMatte.dilateBinary(isBg, width: w, height: h, radius: band)
        var remaining: [Int32] = []
        var value = depth.values
        var done = [Bool](repeating: true, count: n)
        for i in 0..<n {
            let edge = label[i] > 0 ? nearBg[i] > 0 : nearSeg[i] > 0
            if edge && (valid == nil || valid![i] >= 0.5) && value[i].isFinite {
                done[i] = false
                remaining.append(Int32(i))
            }
        }
        guard !remaining.isEmpty else { return depth }
        // 3. 从同一块的可信像素一圈一圈往里填（每一圈只用上一圈结束时已经填好的邻居，结果和遍历顺序无关）
        var round = 0
        var filledIdx: [Int32] = [], filledVal: [Float] = [], still: [Int32] = []
        while !remaining.isEmpty && round < 4 * band + 8 {
            round += 1
            filledIdx.removeAll(keepingCapacity: true); filledVal.removeAll(keepingCapacity: true)
            still.removeAll(keepingCapacity: true)
            value.withUnsafeBufferPointer { V in
            done.withUnsafeBufferPointer { D in
            label.withUnsafeBufferPointer { Lb in
                for top in remaining {
                    let i = Int(top), x = i % w, y = i / w, l = Lb[i]
                    var s: Float = 0, c: Float = 0
                    for yy in max(0, y - 1)...min(h - 1, y + 1) {
                        let row = yy * w
                        for xx in max(0, x - 1)...min(w - 1, x + 1) {
                            let q = row + xx
                            if D[q] && Lb[q] == l { s += V[q]; c += 1 }
                        }
                    }
                    if c > 0 { filledIdx.append(top); filledVal.append(s / c) } else { still.append(top) }
                }
            }}}
            if filledIdx.isEmpty { break }
            for k in 0..<filledIdx.count { let i = Int(filledIdx[k]); value[i] = filledVal[k]; done[i] = true }
            swap(&remaining, &still)
        }
        // 4. 整块都不可信（细条）：人像块用这一块的中位数（隔点取样），背景保持原样
        let leftover = remaining.filter { label[Int($0)] > 0 }
        if !leftover.isEmpty {
            let need = Set(leftover.map { label[Int($0)] })
            var samples: [Int32: [Float]] = [:]
            var i = 0
            while i < n {
                let l = label[i]
                if l > 0, need.contains(l), depth.values[i].isFinite { samples[l, default: []].append(depth.values[i]) }
                i += 3
            }
            var median: [Int32: Float] = [:]
            for (l, var v) in samples where !v.isEmpty { v.sort(); median[l] = v[v.count / 2] }
            for top in leftover { if let m = median[label[Int(top)]] { value[Int(top)] = m } }
        }
        return FloatMap(width: w, height: h, values: value)
    }
}
