import Dispatch

/// 把 0..<count 切成若干块，用所有 CPU 核并行执行。
/// body 必须只写自己负责的那一行/那一块内存。
@inline(__always)
func parallelFor(_ count: Int, _ body: (Int) -> Void) {
    if count <= 0 { return }
    if count < 16 {
        for i in 0..<count { body(i) }
        return
    }
    let chunks = min(count, 64)
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        let start = c * count / chunks
        let end = (c + 1) * count / chunks
        for i in start..<end { body(i) }
    }
}

/// 按块并行：每块拿到一段连续区间，适合需要线程私有缓冲区的循环
@inline(__always)
func parallelChunks(_ count: Int, _ body: (Range<Int>) -> Void) {
    if count <= 0 { return }
    let chunks = min(count, 32)
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        let start = c * count / chunks
        let end = (c + 1) * count / chunks
        if start < end { body(start..<end) }
    }
}
