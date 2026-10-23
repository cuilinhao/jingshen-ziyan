// 景深渲染的 GPU 版本（Metal 计算着色器），运行时用 makeLibrary(source:) 编译。
//
// 每个 kernel 都对应 BokehCore 里 CPU 参考实现的一步（DetailPreserving / DepthRefiner / TemporalState /
// SubjectMatte / BokehRenderer / PullPush），公式、半径、边界处理、求和顺序都照抄，
// macOS 上的 `swift test` 会把两边的结果逐像素对比（Tests/BokehMetalTests）。
//
// 改这里的公式时，CPU 版也要一起改，反之亦然。

enum BokehShaderSource {
    static let code = #"""
#include <metal_stdlib>
using namespace metal;

constant int TILE = 16;      // 分层用的分块大小（低分辨率像素）
constant int BOX_SEG = 16;   // 盒式滤波每个线程负责的一段长度（段内滑动求和）

// ================================================================ 公共

struct LensParams {
    float fNumber;
    float focusDisparity;
    float focalLength35mm;
    float maxBlurFraction;
    float focusTolerance;     // thinLens 的全清晰区（相对距离）
    float blurK;
    float frontTolerance;     // system：对焦面前面的全清晰区、斜率、上限（视差差）
    float frontSlope;
    float frontMax;
    float backTolerance;      // system：对焦面后面的
    float backSlope;
    float backMax;
    float softLimitFraction;
    float longSide;           // 低分辨率图像的长边（像素）
    int model;                // 0 = system, 1 = thinLens
    int pad;
};

// LensParameters.signedBlurRadius（Lens.swift）
inline float signedBlurRadius(float d, constant LensParams& p) {
    float L = p.longSide;
    float maxR = p.maxBlurFraction * L;
    if (p.model == 0) {
        float dd = d - p.focusDisparity;
        float g = dd > 0.0f
            ? p.frontMax * tanh(p.frontSlope * max(dd - p.frontTolerance, 0.0f) / p.frontMax)
            : p.backMax * tanh(p.backSlope * max(-dd - p.backTolerance, 0.0f) / p.backMax);
        float r = g * p.blurK / max(p.fNumber, 1.0f) * L;
        return dd > 0.0f ? min(r, maxR) : -min(r, maxR);
    }
    float f = p.focalLength35mm;
    float delta = d - p.focusDisparity;
    float tol = p.focusTolerance * p.focusDisparity;
    delta = delta > 0.0f ? max(0.0f, delta - tol) : min(0.0f, delta + tol);
    float diameterMM = f * f / p.fNumber * delta / 1000.0f;
    float radiusPx = 0.5f * diameterMM / 36.0f * L;
    if (p.softLimitFraction > 0.0f) {
        float rSat = p.softLimitFraction * L * 4.5f / max(p.fNumber, 0.5f);
        float x = radiusPx / rSat;
        radiusPx /= pow(1.0f + fabs(x * x * x), 1.0f / 3.0f);   // MSL 没有 cbrt
    }
    return min(max(radiusPx, -maxR), maxR);
}

inline float smoothstepf(float a, float b, float x) {
    float t = min(max((x - a) / (b - a), 0.0f), 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float encodeSRGB(float l) {
    l = min(max(l, 0.0f), 1.0f);
    return l <= 0.0031308f ? l * 12.92f : 1.055f * pow(l, 1.0f / 2.4f) - 0.055f;
}

// FloatMap.sampleBilinear：像素坐标（像素中心在 +0.5），边缘夹住
inline float4 bilinearTex(texture2d<float, access::read> t, float x, float y) {
    int w = int(t.get_width()), h = int(t.get_height());
    float fx = min(max(x - 0.5f, 0.0f), float(w - 1));
    float fy = min(max(y - 0.5f, 0.0f), float(h - 1));
    int x0 = int(fx), y0 = int(fy);
    int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
    float tx = fx - float(x0), ty = fy - float(y0);
    float4 a = t.read(uint2(x0, y0)), b = t.read(uint2(x1, y0));
    float4 c = t.read(uint2(x0, y1)), d = t.read(uint2(x1, y1));
    float4 top = a + (b - a) * tx;
    float4 bot = c + (d - c) * tx;
    return top + (bot - top) * ty;
}

inline float4 bilinearBuf(device const float4* p, int w, int h, float x, float y) {
    float fx = min(max(x - 0.5f, 0.0f), float(w - 1));
    float fy = min(max(y - 0.5f, 0.0f), float(h - 1));
    int x0 = int(fx), y0 = int(fy);
    int x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
    float tx = fx - float(x0), ty = fy - float(y0);
    float4 a = p[y0 * w + x0], b = p[y0 * w + x1];
    float4 c = p[y1 * w + x0], d = p[y1 * w + x1];
    float4 top = a + (b - a) * tx;
    float4 bot = c + (d - c) * tx;
    return top + (bot - top) * ty;
}

// 同样大小的图按像素中心双线性缩放（SubjectMatte.sampleAt / FloatMap.resized 的最后一步）
inline float4 resampleTex(texture2d<float, access::read> t, uint2 gid, uint w, uint h) {
    float sx = float(t.get_width()) / float(w), sy = float(t.get_height()) / float(h);
    return bilinearTex(t, (float(gid.x) + 0.5f) * sx, (float(gid.y) + 0.5f) * sy);
}

inline float maxComponent(float3 c) { return max(c.r, max(c.g, c.b)); }

// ================================================================ 1. 缩小 + 亮度

struct DownParams {
    float2 cropOrigin;        // 采样路径：源图的归一化坐标
    float2 cropSize;
    int samples;              // 采样路径：每个轴的采样数
    int boxFactor;            // > 0：整数倍，用 read() 做 k×k 盒式平均（和 CPU 的 downsample 一样）
    int2 boxOrigin;           // 盒式路径：源图的像素坐标
};

kernel void downsampleKernel(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write> low [[texture(1)]],
                             texture2d<float, access::write> luma [[texture(2)]],
                             constant DownParams& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint w = low.get_width(), h = low.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float3 c;
    if (p.boxFactor > 0) {
        int k = p.boxFactor;
        float3 s = float3(0.0f);
        for (int yy = 0; yy < k; yy++) {
            for (int xx = 0; xx < k; xx++) {
                uint2 q = uint2(p.boxOrigin.x + int(gid.x) * k + xx, p.boxOrigin.y + int(gid.y) * k + yy);
                s += src.read(q).rgb;
            }
        }
        c = s * (1.0f / float(k * k));
    } else {
        constexpr sampler smp(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 cell = p.cropSize / float2(float(w), float(h));
        float2 origin = p.cropOrigin + float2(gid) * cell;
        int n = max(p.samples, 1);
        float2 stepv = cell / float(n);
        float3 s = float3(0.0f);
        for (int j = 0; j < n; j++) {
            for (int i = 0; i < n; i++) {
                s += src.sample(smp, origin + (float2(float(i), float(j)) + 0.5f) * stepv).rgb;
            }
        }
        c = s / float(n * n);
    }
    low.write(float4(c, 1.0f), gid);
    float y = 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;
    luma.write(float4(encodeSRGB(y), 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 2. 盒式均值 / 最小值（可分离）

// 盒式均值，边缘只除以图内的像素数（BoxFilter.mean）。每个线程负责一行里连续 BOX_SEG 个像素，段内滑动求和。
// 单通道的图也走这里（读出来是 (v, 0, 0, 1)，写回只留 .x）
kernel void boxHKernel(texture2d<float, access::read> inTex [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       constant int& radius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(outTex.get_width()), h = int(outTex.get_height());
    int x0 = int(gid.x) * BOX_SEG, y = int(gid.y);
    if (x0 >= w || y >= h) { return; }
    int r = radius;
    float4 acc = float4(0.0f);
    for (int x = max(0, x0 - r); x <= min(w - 1, x0 + r); x++) { acc += inTex.read(uint2(x, y)); }
    int x1 = min(w, x0 + BOX_SEG);
    for (int x = x0; x < x1; x++) {
        int lo = max(0, x - r), hi = min(w - 1, x + r);
        outTex.write(acc / float(hi - lo + 1), uint2(x, y));
        int add = x + r + 1, sub = x - r;
        if (add < w) { acc += inTex.read(uint2(add, y)); }
        if (sub >= 0) { acc -= inTex.read(uint2(sub, y)); }
    }
}

kernel void boxVKernel(texture2d<float, access::read> inTex [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       constant int& radius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(outTex.get_width()), h = int(outTex.get_height());
    int x = int(gid.x), y0 = int(gid.y) * BOX_SEG;
    if (x >= w || y0 >= h) { return; }
    int r = radius;
    float4 acc = float4(0.0f);
    for (int y = max(0, y0 - r); y <= min(h - 1, y0 + r); y++) { acc += inTex.read(uint2(x, y)); }
    int y1 = min(h, y0 + BOX_SEG);
    for (int y = y0; y < y1; y++) {
        int lo = max(0, y - r), hi = min(h - 1, y + r);
        float inv = 1.0f / float(hi - lo + 1);
        outTex.write(acc * inv, uint2(x, y));
        int add = y + r + 1, sub = y - r;
        if (add < h) { acc += inTex.read(uint2(x, add)); }
        if (sub >= 0) { acc -= inTex.read(uint2(x, sub)); }
    }
}

kernel void minHKernel(texture2d<float, access::read> inTex [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       constant int& radius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(outTex.get_width()), h = int(outTex.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    int x0 = max(0, int(gid.x) - radius), x1 = min(w - 1, int(gid.x) + radius);
    float m = INFINITY;
    for (int x = x0; x <= x1; x++) { m = min(m, inTex.read(uint2(x, gid.y)).x); }
    outTex.write(float4(m, 0.0f, 0.0f, 0.0f), gid);
}

kernel void minVKernel(texture2d<float, access::read> inTex [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       constant int& radius [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(outTex.get_width()), h = int(outTex.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    int y0 = max(0, int(gid.y) - radius), y1 = min(h - 1, int(gid.y) + radius);
    float m = INFINITY;
    for (int y = y0; y <= y1; y++) { m = min(m, inTex.read(uint2(gid.x, y)).x); }
    outTex.write(float4(m, 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 3. 深度：上采样 + 灰度引导滤波（DepthRefiner）

kernel void upsampleDepthKernel(texture2d<float, access::read> depth [[texture(0)]],
                                texture2d<float, access::write> outTex [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    outTex.write(float4(resampleTex(depth, gid, w, h).x, 0.0f, 0.0f, 0.0f), gid);
}

// (I, p, I·p, I²)
kernel void gfPrepareGrayKernel(texture2d<float, access::read> guide [[texture(0)]],
                                texture2d<float, access::read> input [[texture(1)]],
                                texture2d<float, access::write> outTex [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float I = guide.read(gid).x, pv = input.read(gid).x;
    outTex.write(float4(I, pv, I * pv, I * I), gid);
}

// a = cov / (var + eps)，b = meanP − a·meanI
kernel void gfCoeffGrayKernel(texture2d<float, access::read> means [[texture(0)]],
                              texture2d<float, access::write> outTex [[texture(1)]],
                              constant float& eps [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float4 m = means.read(gid);
    float cov = m.z - m.x * m.y;
    float varI = m.w - m.x * m.x;
    float a = cov / (varI + eps);
    float b = m.y - a * m.x;
    outTex.write(float4(a, b, 0.0f, 0.0f), gid);
}

// q = meanA·I + meanB
kernel void gfApplyGrayKernel(texture2d<float, access::read> guide [[texture(0)]],
                              texture2d<float, access::read> meanAB [[texture(1)]],
                              texture2d<float, access::write> outTex [[texture(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float4 ab = meanAB.read(gid);
    outTex.write(float4(ab.x * guide.read(gid).x + ab.y, 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 4. 跨帧稳定（TemporalState）

struct TemporalParams {
    float strength;           // 已乘上 stillness
    float invSigma;
    int hasHistory;
    int gate;                 // 1 = 新深度来的这一帧：之前被重新对齐过的区域（suspect）不沿用上一帧
};

kernel void temporalDepthKernel(texture2d<float, access::read> luma [[texture(0)]],
                                texture2d<float, access::read> prevLuma [[texture(1)]],
                                texture2d<float, access::read> depth [[texture(2)]],
                                texture2d<float, access::read> prevDepth [[texture(3)]],
                                texture2d<float, access::write> outDepth [[texture(4)]],
                                texture2d<float, access::write> blendOut [[texture(5)]],
                                texture2d<float, access::read> suspect [[texture(6)]],
                                constant TemporalParams& p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int w = int(outDepth.get_width()), h = int(outDepth.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    float d = depth.read(gid).x;
    if (p.hasHistory == 0) {
        outDepth.write(float4(d, 0.0f, 0.0f, 0.0f), gid);
        blendOut.write(float4(0.0f), gid);
        return;
    }
    // 3×3 平均后的亮度差（BoxFilter.mean 半径 1：先水平再垂直，边缘只平均图内的）
    int x0 = max(0, int(gid.x) - 1), x1 = min(w - 1, int(gid.x) + 1);
    int y0 = max(0, int(gid.y) - 1), y1 = min(h - 1, int(gid.y) + 1);
    float colSum = 0.0f;
    for (int y = y0; y <= y1; y++) {
        float rowSum = 0.0f;
        for (int x = x0; x <= x1; x++) {
            uint2 q = uint2(x, y);
            rowSum += fabs(luma.read(q).x - prevLuma.read(q).x);
        }
        colSum += rowSum / float(x1 - x0 + 1);
    }
    float dm = colSum * (1.0f / float(y1 - y0 + 1));
    float xv = dm * p.invSigma;
    float b = p.strength * exp(-xv * xv);
    if (p.gate != 0) { b *= 1.0f - suspect.read(gid).x; }
    float out = d + b * (prevDepth.read(gid).x - d);
    outDepth.write(float4(out, 0.0f, 0.0f, 0.0f), gid);
    blendOut.write(float4(b, 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 4b. 沿用旧深度：把上一帧的深度搬到这一帧（StaleDepth）

constant float STALE_LO = 0.04f;
constant float STALE_HI = 0.10f;
constant int STALE_BLOCK = 4;
constant int STALE_SEARCH = 12;
constant float STALE_OUTSIDE = 3.0f;

inline float3 sqrtColor(float3 c) { return sqrt(max(c, float3(0.0f))); }

// 每个像素两帧颜色差（√线性光，三个通道里最大的）
kernel void staleDiffKernel(texture2d<float, access::read> now [[texture(0)]],
                            texture2d<float, access::read> prev [[texture(1)]],
                            texture2d<float, access::write> outTex [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float3 d = fabs(sqrtColor(now.read(gid).rgb) - sqrtColor(prev.read(gid).rgb));
    outTex.write(float4(max(d.r, max(d.g, d.b)), 0.0f, 0.0f, 0.0f), gid);
}

struct StaleMaskParams {
    int suspectValid;         // suspectIn 有效（上一张新深度以来已经重新对齐过）
    int pad0;
    int pad1;
    int pad2;
};

// U = smoothstep(lo, hi, 5×5 最大差)、Us = smoothstep(lo, hi, 11×11 最大差)；suspect 累积 U
kernel void staleMaskKernel(texture2d<float, access::read> diff [[texture(0)]],
                            texture2d<float, access::read> suspectIn [[texture(1)]],
                            texture2d<float, access::write> uOut [[texture(2)]],
                            texture2d<float, access::write> usOut [[texture(3)]],
                            texture2d<float, access::write> suspectOut [[texture(4)]],
                            constant StaleMaskParams& p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int w = int(uOut.get_width()), h = int(uOut.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x >= w || y >= h) { return; }
    float m2 = 0.0f, m5 = 0.0f;
    for (int yy = max(0, y - 5); yy <= min(h - 1, y + 5); yy++) {
        for (int xx = max(0, x - 5); xx <= min(w - 1, x + 5); xx++) {
            float v = diff.read(uint2(xx, yy)).x;
            m5 = max(m5, v);
            if (xx >= x - 2 && xx <= x + 2 && yy >= y - 2 && yy <= y + 2) { m2 = max(m2, v); }
        }
    }
    float u = smoothstepf(STALE_LO, STALE_HI, m2);
    uOut.write(float4(u, 0.0f, 0.0f, 0.0f), gid);
    usOut.write(float4(smoothstepf(STALE_LO, STALE_HI, m5), 0.0f, 0.0f, 0.0f), gid);
    float s = p.suspectValid != 0 ? max(suspectIn.read(gid).x, u) : u;
    suspectOut.write(float4(s, 0.0f, 0.0f, 0.0f), gid);
}

// 1/4 分辨率的 √颜色（每块线性光取平均再开方，边上的块只算图内的像素）、每块最大的 U
kernel void staleQuarterKernel(texture2d<float, access::read> now [[texture(0)]],
                               texture2d<float, access::read> prev [[texture(1)]],
                               texture2d<float, access::read> u [[texture(2)]],
                               texture2d<float, access::write> qNow [[texture(3)]],
                               texture2d<float, access::write> qPrev [[texture(4)]],
                               texture2d<float, access::write> qU [[texture(5)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int bw = int(qNow.get_width()), bh = int(qNow.get_height());
    if (int(gid.x) >= bw || int(gid.y) >= bh) { return; }
    int w = int(now.get_width()), h = int(now.get_height());
    int x0 = int(gid.x) * STALE_BLOCK, x1 = min(w, x0 + STALE_BLOCK);
    int y0 = int(gid.y) * STALE_BLOCK, y1 = min(h, y0 + STALE_BLOCK);
    float3 sn = float3(0.0f), sp = float3(0.0f);
    float mu = 0.0f;
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            uint2 q = uint2(x, y);
            sn += now.read(q).rgb;
            sp += prev.read(q).rgb;
            mu = max(mu, u.read(q).x);
        }
    }
    float inv = 1.0f / float((x1 - x0) * (y1 - y0));
    qNow.write(float4(sqrtColor(sn * inv), 1.0f), gid);
    qPrev.write(float4(sqrtColor(sp * inv), 1.0f), gid);
    qU.write(float4(mu, 0.0f, 0.0f, 0.0f), gid);
}

// 块 (bx, by) 移动 (dx, dy) 块后的 3×3 色块差
inline float staleBlockCost(texture2d<float, access::read> qNow, texture2d<float, access::read> qPrev,
                            int bx, int by, int dx, int dy, int bw, int bh) {
    float s = 0.0f;
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            int ax = clamp(bx + ox, 0, bw - 1), ay = clamp(by + oy, 0, bh - 1);
            int sx = ax + dx, sy = ay + dy;
            if (sx < 0 || sy < 0 || sx >= bw || sy >= bh) { s += STALE_OUTSIDE; continue; }
            float3 a = qNow.read(uint2(ax, ay)).rgb, b = qPrev.read(uint2(sx, sy)).rgb;
            s += fabs(a.r - b.r) + fabs(a.g - b.g) + fabs(a.b - b.b);
        }
    }
    return s;
}

// 每块的运动（块为单位，±STALE_SEARCH）。周围 3×3 块都没变的块不算
kernel void staleFlowKernel(texture2d<float, access::read> qNow [[texture(0)]],
                            texture2d<float, access::read> qPrev [[texture(1)]],
                            texture2d<float, access::read> qU [[texture(2)]],
                            texture2d<float, access::write> flowOut [[texture(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int bw = int(qNow.get_width()), bh = int(qNow.get_height());
    int bx = int(gid.x), by = int(gid.y);
    if (bx >= bw || by >= bh) { return; }
    bool active = false;
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            int nx = bx + ox, ny = by + oy;
            if (nx >= 0 && ny >= 0 && nx < bw && ny < bh && qU.read(uint2(nx, ny)).x > 0.001f) { active = true; }
        }
    }
    if (!active) {
        flowOut.write(float4(0.0f), gid);
        return;
    }
    float best = staleBlockCost(qNow, qPrev, bx, by, 0, 0, bw, bh);
    int bdx = 0, bdy = 0;
    for (int dy = -STALE_SEARCH; dy <= STALE_SEARCH; dy++) {
        for (int dx = -STALE_SEARCH; dx <= STALE_SEARCH; dx++) {
            if (dx == 0 && dy == 0) { continue; }
            float c = staleBlockCost(qNow, qPrev, bx, by, dx, dy, bw, bh);
            if (c < best) { best = c; bdx = dx; bdy = dy; }
        }
    }
    flowOut.write(float4(float(bdx), float(bdy), 0.0f, 0.0f), gid);
}

// 变了的像素：在相邻 3×3 块的运动里挑全分辨率 3×3 色块差最小的，取上一帧那里的深度
kernel void staleWarpKernel(texture2d<float, access::read> depth [[texture(0)]],
                            texture2d<float, access::read> now [[texture(1)]],
                            texture2d<float, access::read> prev [[texture(2)]],
                            texture2d<float, access::read> u [[texture(3)]],
                            texture2d<float, access::read> flow [[texture(4)]],
                            texture2d<float, access::write> outTex [[texture(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int w = int(outTex.get_width()), h = int(outTex.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x >= w || y >= h) { return; }
    float d = depth.read(gid).x;
    float ui = u.read(gid).x;
    if (ui <= 0.001f) {
        outTex.write(float4(d, 0.0f, 0.0f, 0.0f), gid);
        return;
    }
    int bw = int(flow.get_width()), bh = int(flow.get_height());
    int bx = x / STALE_BLOCK, by = y / STALE_BLOCK;
    float best = INFINITY;
    int vx = 0, vy = 0;
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            int nx = clamp(bx + ox, 0, bw - 1), ny = clamp(by + oy, 0, bh - 1);
            float2 f = flow.read(uint2(nx, ny)).xy;
            int cx = int(f.x) * STALE_BLOCK, cy = int(f.y) * STALE_BLOCK;
            float s = 0.0f;
            for (int py = -1; py <= 1; py++) {
                for (int px = -1; px <= 1; px++) {
                    int ax = clamp(x + px, 0, w - 1), ay = clamp(y + py, 0, h - 1);
                    int sx = clamp(ax + cx, 0, w - 1), sy = clamp(ay + cy, 0, h - 1);
                    float3 a = sqrtColor(now.read(uint2(ax, ay)).rgb), b = sqrtColor(prev.read(uint2(sx, sy)).rgb);
                    s += fabs(a.r - b.r) + fabs(a.g - b.g) + fabs(a.b - b.b);
                }
            }
            if (s < best) { best = s; vx = cx; vy = cy; }
        }
    }
    int sx = clamp(x + vx, 0, w - 1), sy = clamp(y + vy, 0, h - 1);
    outTex.write(float4(d + ui * (depth.read(uint2(sx, sy)).x - d), 0.0f, 0.0f, 0.0f), gid);
}

// 变了的区域附近（Us > 0）换成按这一帧亮度引导滤波后的深度
kernel void staleSnapKernel(texture2d<float, access::read> warped [[texture(0)]],
                            texture2d<float, access::read> filtered [[texture(1)]],
                            texture2d<float, access::read> us [[texture(2)]],
                            texture2d<float, access::write> outTex [[texture(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float v = warped.read(gid).x;
    float s = us.read(gid).x;
    if (s > 0.0f) { v += s * (filtered.read(gid).x - v); }
    outTex.write(float4(v, 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 5. 主体遮罩（SubjectMatte.apply）

struct SubjectParams {
    float focusDisparity;
    float normScale;          // max(relativeScale ?? d_f, 1e-3)
    float band;
    float eps;
    int hasConnect;
    int hasExtra;
    int hasPerson;
    int pad;
};

// 深度核心 = |相对距离| < band 且（没有连通限制 或 connect ≥ 0.5）；核心 = 深度核心 或 extra ≥ 0.5
kernel void subjectCoreKernel(texture2d<float, access::read> depth [[texture(0)]],
                              texture2d<float, access::read> connect [[texture(1)]],
                              texture2d<float, access::read> extra [[texture(2)]],
                              texture2d<float, access::write> coreOut [[texture(3)]],
                              texture2d<float, access::write> depthCoreOut [[texture(4)]],
                              constant SubjectParams& p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint w = coreOut.get_width(), h = coreOut.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float d = depth.read(gid).x;
    bool inBand = fabs((d - p.focusDisparity) / p.normScale) < p.band;
    bool connected = p.hasConnect == 0 || resampleTex(connect, gid, w, h).x >= 0.5f;
    float dc = (inBand && connected) ? 1.0f : 0.0f;
    bool add = p.hasExtra != 0 && resampleTex(extra, gid, w, h).x >= 0.5f;
    coreOut.write(float4((dc > 0.0f || add) ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f), gid);
    depthCoreOut.write(float4(dc, 0.0f, 0.0f, 0.0f), gid);
}

// 彩色引导滤波的输入：I_c = sqrt(线性光)，p = 核心
//   m1 = (I_r, I_g, I_b, p)   m2 = (I·p, 0)   m3 = (I², 0)
kernel void gfPrepareColorKernel(texture2d<float, access::read> low [[texture(0)]],
                                 texture2d<float, access::read> core [[texture(1)]],
                                 texture2d<float, access::write> m1 [[texture(2)]],
                                 texture2d<float, access::write> m2 [[texture(3)]],
                                 texture2d<float, access::write> m3 [[texture(4)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= m1.get_width() || gid.y >= m1.get_height()) { return; }
    float3 I = sqrt(max(low.read(gid).rgb, float3(0.0f)));
    float pv = core.read(gid).x;
    m1.write(float4(I, pv), gid);
    m2.write(float4(I * pv, 0.0f), gid);
    m3.write(float4(I * I, 0.0f), gid);
}

kernel void gfCoeffColorKernel(texture2d<float, access::read> m1 [[texture(0)]],
                               texture2d<float, access::read> m2 [[texture(1)]],
                               texture2d<float, access::read> m3 [[texture(2)]],
                               texture2d<float, access::write> outA [[texture(3)]],
                               texture2d<float, access::write> outB [[texture(4)]],
                               constant float& eps [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outA.get_width() || gid.y >= outA.get_height()) { return; }
    float4 a1 = m1.read(gid);
    float3 meanI = a1.rgb;
    float meanP = a1.a;
    float3 cov = m2.read(gid).rgb - meanI * meanP;
    float3 varI = m3.read(gid).rgb - meanI * meanI;
    float3 a = cov / (varI + eps);
    float3 b = meanP - a * meanI;
    outA.write(float4(a, 0.0f), gid);
    outB.write(float4(b, 0.0f), gid);
}

// α = smoothstep(0.25, 0.75, 三个通道结果的平均)，再和 smoothstep(0.3, 0.7, person) 取最大
kernel void gfApplyColorKernel(texture2d<float, access::read> low [[texture(0)]],
                               texture2d<float, access::read> meanA [[texture(1)]],
                               texture2d<float, access::read> meanB [[texture(2)]],
                               texture2d<float, access::read> person [[texture(3)]],
                               texture2d<float, access::write> alphaOut [[texture(4)]],
                               constant SubjectParams& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    uint w = alphaOut.get_width(), h = alphaOut.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float3 I = sqrt(max(low.read(gid).rgb, float3(0.0f)));
    float3 q = meanA.read(gid).rgb * I + meanB.read(gid).rgb;
    // CPU 是逐通道累加 (q_c) / 3
    float avg = 0.0f;
    avg += q.r / 3.0f;
    avg += q.g / 3.0f;
    avg += q.b / 3.0f;
    float a = smoothstepf(0.25f, 0.75f, avg);
    if (p.hasPerson != 0) {
        a = max(a, smoothstepf(0.3f, 0.7f, resampleTex(person, gid, w, h).x));
    }
    alphaOut.write(float4(a, 0.0f, 0.0f, 0.0f), gid);
}

// 视差 = d + α(d_f − d)；深度核心里但 α 低的（深度渗出来的），推向附近更远的视差
kernel void subjectFixKernel(texture2d<float, access::read> depth [[texture(0)]],
                             texture2d<float, access::read> alpha [[texture(1)]],
                             texture2d<float, access::read> depthCore [[texture(2)]],
                             texture2d<float, access::read> farNearby [[texture(3)]],
                             texture2d<float, access::write> outTex [[texture(4)]],
                             constant SubjectParams& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float d = depth.read(gid).x;
    float a = alpha.read(gid).x;
    float df = p.focusDisparity;
    float v = d + a * (df - d);
    float leak = max(0.0f, depthCore.read(gid).x - a);
    float fn = farNearby.read(gid).x;
    if (leak > 0.0f && fn < df - p.band * p.normScale) {
        v += leak * (fn - v);
    }
    outTex.write(float4(v, 0.0f, 0.0f, 0.0f), gid);
}

// ================================================================ 6. 模糊半径、分层位置、高光（BokehRenderer.render 1–3）

struct LayerParams {
    int count;                // 层数
    int zeroIndex;            // 对焦层
    int tilesX;
    int tilesY;
    float highlightThreshold;
    float highlightGain;      // 0 = 不提亮
    int hasBoostHistory;
    int pad;
};

// s = 带符号的模糊半径；layerOut = (lo, t)（lo 层占 1 − t，lo+1 层占 t）；maxC = max(r, g, b)
kernel void cocKernel(texture2d<float, access::read> depth [[texture(0)]],
                      texture2d<float, access::read> low [[texture(1)]],
                      texture2d<float, access::write> sOut [[texture(2)]],
                      texture2d<float, access::write> maxCOut [[texture(3)]],
                      device float2* layerOut [[buffer(0)]],
                      constant LensParams& lens [[buffer(1)]],
                      constant float* centers [[buffer(2)]],
                      constant LayerParams& lp [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= sOut.get_width() || gid.y >= sOut.get_height()) { return; }
    float d = depth.read(gid).x;
    float v = isfinite(d) ? signedBlurRadius(d, lens) : 0.0f;
    int n = lp.count;
    int j = 0;
    float t = 0.0f;
    if (v <= centers[0]) {
        j = 0;
    } else if (v >= centers[n - 1]) {
        j = n - 1;
    } else {
        while (j + 1 < n && centers[j + 1] <= v) { j++; }
        if (j + 1 < n) { t = (v - centers[j]) / (centers[j + 1] - centers[j]); }
    }
    sOut.write(float4(v, 0.0f, 0.0f, 0.0f), gid);
    layerOut[gid.y * sOut.get_width() + gid.x] = float2(float(j), t);
    maxCOut.write(float4(maxComponent(low.read(gid).rgb), 0.0f, 0.0f, 0.0f), gid);
}

// 高光提亮（平滑版）+ 跨帧稳定。输出 src = 颜色 × 提亮 —— 分层模糊的输入
kernel void boostKernel(texture2d<float, access::read> low [[texture(0)]],
                        texture2d<float, access::read> sTex [[texture(1)]],
                        texture2d<float, access::read> maxC [[texture(2)]],
                        texture2d<float, access::read> localMean [[texture(3)]],
                        texture2d<float, access::read> prevBoost [[texture(4)]],
                        texture2d<float, access::read> blend [[texture(5)]],
                        texture2d<float, access::write> boostOut [[texture(6)]],
                        device float4* srcOut [[buffer(0)]],
                        constant LayerParams& lp [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint w = boostOut.get_width(), h = boostOut.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    float thr = lp.highlightThreshold, gain = lp.highlightGain;
    float b = 1.0f;
    if (gain > 0.0f) {
        float m = maxC.read(gid).x;
        if (m > thr) {
            float blurAmount = min(1.0f, fabs(sTex.read(gid).x) / 2.0f);
            float k = smoothstepf(thr, 1.0f, m);
            float contrast = smoothstepf(0.1f, 0.4f, m - localMean.read(gid).x);
            b = 1.0f + gain * k * k * contrast * blurAmount;
        }
        if (lp.hasBoostHistory != 0) {
            b += blend.read(gid).x * (prevBoost.read(gid).x - b);
        }
    }
    boostOut.write(float4(b, 0.0f, 0.0f, 0.0f), gid);
    float3 c = low.read(gid).rgb;
    if (b != 1.0f) { c *= b; }
    srcOut[gid.y * w + gid.x] = float4(c, 0.0f);
}

// ================================================================ 7. 分层模糊（BokehRenderer.renderLayer / diskBlur）

inline float layerWeight(float2 lt, int k) {
    int l = int(lt.x);
    if (l == k) { return 1.0f - lt.y; }
    if (l + 1 == k) { return lt.y; }
    return 0.0f;
}

// 每个分块（TILE×TILE）里出现了哪些层（位掩码）。每个线程负责一个分块的一行
kernel void layerTilesKernel(device const float2* layerPos [[buffer(0)]],
                             device atomic_uint* tiles [[buffer(1)]],
                             constant LayerParams& lp [[buffer(2)]],
                             constant int2& size [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int w = size.x, h = size.y;
    int tx = int(gid.x), y = int(gid.y);
    if (tx >= lp.tilesX || y >= h) { return; }
    uint bits = 0u;
    for (int x = tx * TILE; x < min(w, tx * TILE + TILE); x++) {
        float2 lt = layerPos[y * w + x];
        int l = int(lt.x);
        if (lt.y < 1.0f) { bits |= (1u << uint(l)); }
        if (lt.y > 0.0f && l + 1 < lp.count) { bits |= (1u << uint(l + 1)); }
    }
    if (bits != 0u) {
        atomic_fetch_or_explicit(&tiles[(y / TILE) * lp.tilesX + tx], bits, memory_order_relaxed);
    }
}

// 每层的位按这一层模糊能「够到」的距离（reach[k] 个分块）向外扩
kernel void dilateTilesKernel(device const uint* tiles [[buffer(0)]],
                              device uint* dilated [[buffer(1)]],
                              device uint* rowMask [[buffer(2)]],
                              constant int* reach [[buffer(3)]],
                              constant LayerParams& lp [[buffer(4)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int tx = lp.tilesX, ty = lp.tilesY;
    int cx = int(gid.x), cy = int(gid.y);
    if (cx >= tx || cy >= ty) { return; }
    uint out = 0u;
    for (int k = 0; k < lp.count; k++) {
        uint bit = 1u << uint(k);
        int D = reach[k];
        bool found = false;
        for (int y = max(0, cy - D); y <= min(ty - 1, cy + D) && !found; y++) {
            for (int x = max(0, cx - D); x <= min(tx - 1, cx + D); x++) {
                if ((tiles[y * tx + x] & bit) != 0u) { found = true; break; }
            }
        }
        if (found) { out |= bit; }
    }
    dilated[cy * tx + cx] = out;
    if (cx == 0) {
        uint m = 0u;
        for (int x = 0; x < tx; x++) { m |= tiles[cy * tx + x]; }
        rowMask[cy] = m;
    }
}

struct LayerPass {
    int layer;
    int q;                    // 这一层先缩小几倍再模糊（downsampleFactor）
    int planeW;               // 缩小后的尺寸
    int planeH;
    int fullW;                // 低分辨率图像的尺寸
    int fullH;
    int additive;             // 0 = over 合成（背景），1 = 加法累积（前景）
    int tilesX;
    float radius;             // 缩小后的模糊半径
    int pad0;
    int pad1;
    int pad2;
};

// 这一层在缩小后的 (px, py) 上的预乘颜色：q×q 盒式平均（边缘按实际像素数）
inline float4 planeValue(device const float4* src, device const float2* layerPos, int px, int py,
                         constant LayerPass& lp) {
    int k = lp.layer, W = lp.fullW;
    if (lp.q == 1) {
        int i = py * W + px;
        float a = layerWeight(layerPos[i], k);
        return float4(src[i].rgb * a, a);
    }
    float4 s = float4(0.0f);
    float cnt = 0.0f;
    for (int y = py * lp.q; y < min(lp.fullH, py * lp.q + lp.q); y++) {
        for (int x = px * lp.q; x < min(W, px * lp.q + lp.q); x++) {
            int i = y * W + x;
            float a = layerWeight(layerPos[i], k);
            s += float4(src[i].rgb * a, a);
            cnt += 1.0f;
        }
    }
    float inv = 1.0f / cnt;
    return s * inv;
}

inline void compositeInto(device float4* acc, int i, float4 c, int additive) {
    if (additive != 0) {
        acc[i] += c;
    } else {
        float4 o = acc[i];
        float k = 1.0f - c.a;
        acc[i] = float4(o.rgb * k + c.rgb, o.a * k + c.a);
    }
}

// 逐行前缀和：prefix[y][x] = 这一行 [0, x) 的累加（每行 W+1 个）。一个线程组（64 个线程）负责一行
kernel void layerPrefixKernel(device const float4* src [[buffer(0)]],
                              device const float2* layerPos [[buffer(1)]],
                              device float4* prefix [[buffer(2)]],
                              device const uint* rowMask [[buffer(3)]],
                              constant LayerPass& lp [[buffer(4)]],
                              uint row [[threadgroup_position_in_grid]],
                              uint tid [[thread_index_in_threadgroup]],
                              uint nt [[threads_per_threadgroup]]) {
    threadgroup float4 partial[64];
    int W = lp.planeW;
    if (int(row) >= lp.planeH) { return; }
    device float4* P = prefix + int(row) * (W + 1);
    uint bit = 1u << uint(lp.layer);
    if ((rowMask[(int(row) * lp.q) / TILE] & bit) == 0u) {
        for (int x = int(tid); x <= W; x += int(nt)) { P[x] = float4(0.0f); }
        return;
    }
    int seg = (W + int(nt) - 1) / int(nt);
    int x0 = int(tid) * seg, x1 = min(W, x0 + seg);
    float4 s = float4(0.0f);
    for (int x = x0; x < x1; x++) { s += planeValue(src, layerPos, x, int(row), lp); }
    partial[tid] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float4 run = float4(0.0f);
        for (uint i = 0; i < nt; i++) {
            float4 v = partial[i];
            partial[i] = run;
            run += v;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float4 run = partial[tid];
    if (tid == 0) { P[0] = float4(0.0f); }
    for (int x = x0; x < x1; x++) {
        run += planeValue(src, layerPos, x, int(row), lp);
        P[x + 1] = run;
    }
}

// 圆盘模糊（抗锯齿边缘：每行的半宽带小数，小数位置的前缀和线性插值），按图内的核面积归一化。
// q == 1 直接合成到 acc；q > 1 写到 lowOut（之后放大再合成）
kernel void layerDiskKernel(device const float4* prefix [[buffer(0)]],
                            device float4* acc [[buffer(1)]],
                            device float4* lowOut [[buffer(2)]],
                            device const uint* dilated [[buffer(3)]],
                            constant LayerPass& lp [[buffer(4)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int W = lp.planeW, H = lp.planeH;
    int px = int(gid.x), py = int(gid.y);
    if (px >= W || py >= H) { return; }
    bool direct = lp.q == 1;
    int idx = py * W + px;
    uint bit = 1u << uint(lp.layer);
    if ((dilated[((py * lp.q) / TILE) * lp.tilesX + (px * lp.q) / TILE] & bit) == 0u) {
        if (!direct) { lowOut[idx] = float4(0.0f); }
        return;
    }
    float r = lp.radius;
    int Ri = int(r);
    float fw = float(W);
    float x = float(px);
    float4 sum = float4(0.0f);
    float norm = 0.0f;
    for (int dy = -Ri; dy <= Ri; dy++) {
        int yy = py + dy;
        if (yy < 0 || yy >= H) { continue; }
        float hw = sqrt(max(0.0f, r * r - float(dy * dy)));
        float a = x - hw, b = x + 1.0f + hw;
        norm += min(b, fw) - max(a, 0.0f);
        float ca = min(max(a, 0.0f), fw), cb = min(max(b, 0.0f), fw);
        if (cb > ca) {
            int ia = int(ca), ib = int(cb);
            float fa = ca - float(ia), fb = cb - float(ib);
            int ja = min(ia + 1, W), jb = min(ib + 1, W);
            device const float4* P = prefix + yy * (W + 1);
            float4 pa = P[ia], pb = P[ib];
            sum += (pb + (P[jb] - pb) * fb) - (pa + (P[ja] - pa) * fa);
        }
    }
    float4 o = float4(0.0f);
    if (norm > 0.0f) {
        float inv = 1.0f / norm;
        float al = sum.a * inv;
        if (al > 1e-5f) { o = float4(sum.rgb * inv, min(al, 1.0f)); }
    }
    if (!direct) {
        lowOut[idx] = o;
    } else if (o.a > 0.0f) {
        compositeInto(acc, idx, o, lp.additive);
    }
}

// q > 1：低分辨率模糊结果双线性放大回来再合成
kernel void layerUpsampleKernel(device const float4* lowOut [[buffer(0)]],
                                device float4* acc [[buffer(1)]],
                                device const uint* dilated [[buffer(2)]],
                                constant LayerPass& lp [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= lp.fullW || y >= lp.fullH) { return; }
    uint bit = 1u << uint(lp.layer);
    if ((dilated[(y / TILE) * lp.tilesX + x / TILE] & bit) == 0u) { return; }
    int lw = lp.planeW, lh = lp.planeH;
    float invQ = 1.0f / float(lp.q);
    float sy = min(max((float(y) + 0.5f) * invQ - 0.5f, 0.0f), float(lh - 1));
    float sx = min(max((float(x) + 0.5f) * invQ - 0.5f, 0.0f), float(lw - 1));
    int y0 = int(sy), y1 = min(y0 + 1, lh - 1);
    int x0 = int(sx), x1 = min(x0 + 1, lw - 1);
    float ty = sy - float(y0), tx = sx - float(x0);
    float4 a = lowOut[y0 * lw + x0], b = lowOut[y0 * lw + x1];
    float4 c = lowOut[y1 * lw + x0], d = lowOut[y1 * lw + x1];
    float4 top = a + (b - a) * tx;
    float4 bot = c + (d - c) * tx;
    float4 v = top + (bot - top) * ty;
    if (v.a <= 1e-5f) { return; }
    compositeInto(acc, y * lp.fullW + x, float4(v.rgb, min(v.a, 1.0f)), lp.additive);
}

// 半径小于半个像素：不模糊，直接按权重合成
kernel void layerDirectKernel(device const float4* src [[buffer(0)]],
                              device const float2* layerPos [[buffer(1)]],
                              device float4* acc [[buffer(2)]],
                              device const uint* dilated [[buffer(3)]],
                              constant LayerPass& lp [[buffer(4)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= lp.fullW || y >= lp.fullH) { return; }
    uint bit = 1u << uint(lp.layer);
    if ((dilated[(y / TILE) * lp.tilesX + x / TILE] & bit) == 0u) { return; }
    int i = y * lp.fullW + x;
    float a = layerWeight(layerPos[i], lp.layer);
    if (a > 0.0f) { compositeInto(acc, i, float4(src[i].rgb * a, a), lp.additive); }
}

kernel void clearKernel(device float4* buf [[buffer(0)]],
                        constant uint& count [[buffer(1)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid < count) { buf[gid] = float4(0.0f); }
}

kernel void clearUIntKernel(device uint* buf [[buffer(0)]],
                            constant uint& count [[buffer(1)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid < count) { buf[gid] = 0u; }
}

// ================================================================ 8. 拉推法补洞（PullPush.fill）

struct LevelDims {
    int w;                    // 这一级
    int h;
    int cw;                   // pull：上一级（更细）；push：下一级（更粗）
    int ch;
};

kernel void pullKernel(device const float4* child [[buffer(0)]],
                       device float4* parent [[buffer(1)]],
                       constant LevelDims& d [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= d.w || y >= d.h) { return; }
    float ws = 0.0f;
    for (int dy = 0; dy < 2; dy++) {
        if (2 * y + dy >= d.ch) { continue; }
        for (int dx = 0; dx < 2; dx++) {
            if (2 * x + dx >= d.cw) { continue; }
            ws += child[(2 * y + dy) * d.cw + 2 * x + dx].a;
        }
    }
    // 权重饱和到 1：有效数据足够的格子不再继续累加
    float s = ws > 1.0f ? 1.0f / ws : 1.0f;
    float3 cs = float3(0.0f);
    for (int dy = 0; dy < 2; dy++) {
        if (2 * y + dy >= d.ch) { continue; }
        for (int dx = 0; dx < 2; dx++) {
            if (2 * x + dx >= d.cw) { continue; }
            cs += child[(2 * y + dy) * d.cw + 2 * x + dx].rgb;
        }
    }
    parent[y * d.w + x] = float4(cs * s, ws * s);
}

kernel void pushTopKernel(device const float4* level [[buffer(0)]],
                          device float4* filled [[buffer(1)]],
                          uint gid [[thread_position_in_grid]]) {
    if (gid != 0) { return; }
    float4 v = level[0];
    filled[0] = v.a > 0.0f ? float4(v.rgb / v.a, 1.0f) : float4(0.0f, 0.0f, 0.0f, 1.0f);
}

kernel void pushKernel(device const float4* level [[buffer(0)]],
                       device const float4* coarse [[buffer(1)]],
                       device float4* filled [[buffer(2)]],
                       constant LevelDims& d [[buffer(3)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= d.w || y >= d.h) { return; }
    int i = y * d.w + x;
    float4 v = level[i];
    if (v.a >= 1.0f) {
        filled[i] = float4(v.rgb, 1.0f);
        return;
    }
    float sx = float(d.cw) / float(d.w), sy = float(d.ch) / float(d.h);
    float3 up = bilinearBuf(coarse, d.cw, d.ch, (float(x) + 0.5f) * sx, (float(y) + 0.5f) * sy).rgb;
    filled[i] = float4(v.rgb + (1.0f - v.a) * up, 1.0f);
}

// 背景归一化（覆盖率低的地方用补出来的背景）+ 前景整体盖上去 → 低分辨率虚化结果
kernel void finishBokehKernel(device const float4* acc [[buffer(0)]],
                              device const float4* filled [[buffer(1)]],
                              device const float4* fg [[buffer(2)]],
                              constant int& hasForeground [[buffer(3)]],
                              texture2d<float, access::write> outTex [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) { return; }
    uint i = gid.y * w + gid.x;
    float3 o = filled[i].rgb;
    float4 a4 = acc[i];
    float a = a4.a;
    if (a > 0.3f) {
        float s = smoothstepf(0.3f, 0.7f, a), inv = 1.0f / a;
        o = a4.rgb * inv * s + o * (1.0f - s);
    }
    if (hasForeground != 0) {
        float4 c = fg[i];
        if (c.a > 1e-5f) {
            // 覆盖率超过 1（不同前景物体的虚化互相重叠）时按权重平均颜色
            float coverage = min(c.a, 1.0f), scale = coverage / c.a;
            float k = 1.0f - coverage;
            o = o * k + c.rgb * scale;
        }
    }
    outTex.write(float4(o, 1.0f), gid);
}

// ================================================================ 9. 虚化程度 w、焦外跨帧稳定、合成（DetailPreserving）

kernel void defocusWeightKernel(texture2d<float, access::read> depth [[texture(0)]],
                                texture2d<float, access::read> low [[texture(1)]],
                                texture2d<float, access::read> bokeh [[texture(2)]],
                                texture2d<float, access::write> wOut [[texture(3)]],
                                constant LensParams& lens [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= wOut.get_width() || gid.y >= wOut.get_height()) { return; }
    float r = fabs(signedBlurRadius(depth.read(gid).x, lens));
    float own = smoothstepf(0.25f, 0.9f, r);
    float3 d = fabs(bokeh.read(gid).rgb - low.read(gid).rgb);
    float spill = smoothstepf(0.015f, 0.06f, max(d.r, max(d.g, d.b)));
    wOut.write(float4(max(own, spill), 0.0f, 0.0f, 0.0f), gid);
}

kernel void stabilizeBokehKernel(texture2d<float, access::read> bokeh [[texture(0)]],
                                 texture2d<float, access::read> prevBokeh [[texture(1)]],
                                 texture2d<float, access::read> wTex [[texture(2)]],
                                 texture2d<float, access::write> outTex [[texture(3)]],
                                 constant TemporalParams& p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float3 c = bokeh.read(gid).rgb;
    float wi = wTex.read(gid).x;
    if (p.hasHistory != 0 && wi > 0.01f) {
        float3 pc = prevBokeh.read(gid).rgb;
        float ref = 0.04f + max(max(c.r, c.g), max(c.b, max(pc.r, max(pc.g, pc.b))));
        float3 dd = fabs(c - pc);
        float d = max(dd.r, max(dd.g, dd.b)) / ref * p.invSigma;
        float beta = p.strength * wi * exp(-d * d);
        c = c + beta * (pc - c);
    }
    outTex.write(float4(c, 1.0f), gid);
}

struct CompositeParams {
    float2 cropOrigin;        // 采样路径：源图的归一化坐标
    float2 cropSize;
    int2 readOrigin;          // 直接读路径（输出和裁出来的那块一样大）：源图的像素坐标
    int directRead;
    int encodeSRGB;           // 1 = 输出 sRGB 编码值（显示用 bgra8Unorm），0 = 线性光（测试）
    int effect;               // 0 = 没有虚化，直接输出原图；1 = 双分辨率合成；2 = 只输出虚化结果
    int pad0;
    int pad1;
    int pad2;
};

// 输出 = 放大(虚化) + (1 − 放大(w)) × (原图 − 放大(低分辨率原图))
kernel void compositeKernel(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::read> low [[texture(1)]],
                            texture2d<float, access::read> bokeh [[texture(2)]],
                            texture2d<float, access::read> wTex [[texture(3)]],
                            texture2d<float, access::write> outTex [[texture(4)]],
                            constant CompositeParams& p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    float3 full;
    if (p.directRead != 0) {
        full = src.read(uint2(int2(gid) + p.readOrigin)).rgb;
    } else {
        constexpr sampler smp(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5f) / float2(float(W), float(H));
        full = src.sample(smp, p.cropOrigin + uv * p.cropSize).rgb;
    }
    float3 o = full;
    if (p.effect != 0) {
        float sx = float(low.get_width()) / float(W), sy = float(low.get_height()) / float(H);
        float fx = (float(gid.x) + 0.5f) * sx, fy = (float(gid.y) + 0.5f) * sy;
        if (p.effect == 2) {
            // 模糊就在全分辨率上算的（低分辨率和输出一样大）：直接输出虚化结果
            o = bilinearTex(bokeh, fx, fy).rgb;
        } else {
            float keep = 1.0f - bilinearTex(wTex, fx, fy).x;
            o = bilinearTex(bokeh, fx, fy).rgb + keep * (full - bilinearTex(low, fx, fy).rgb);
        }
    }
    if (p.encodeSRGB != 0) {
        o = float3(encodeSRGB(o.r), encodeSRGB(o.g), encodeSRGB(o.b));
    }
    outTex.write(float4(o, 1.0f), gid);
}

// ================================================================ 10. 显示（画到屏幕上）

struct DisplayVertexOut {
    float4 position [[position]];
    float2 uv;
};

// 一个盖住整个屏幕的三角形；uv 原点在左上
vertex DisplayVertexOut displayVertex(uint vid [[vertex_id]]) {
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    DisplayVertexOut o;
    o.position = float4(pos * 2.0f - 1.0f, 0.0f, 1.0f);
    o.uv = float2(pos.x, 1.0f - pos.y);
    return o;
}

struct DisplayParams {
    // 屏幕 uv → 帧 uv：f = (a·u + b·v + tx, c·u + d·v + ty)（旋转、按比例放进视图、残余放大）
    float a; float b; float c; float d; float tx; float ty;
    // 换相机时盖在上面、正在淡出的上一帧
    float pa; float pb; float pc; float pd; float ptx; float pty;
    float previousMix;        // 0 = 不显示上一帧
    float pad0; float pad1; float pad2;
};

inline bool insideUnit(float2 f) {
    return f.x >= 0.0f && f.x <= 1.0f && f.y >= 0.0f && f.y <= 1.0f;
}

fragment float4 displayFragment(DisplayVertexOut in [[stage_in]],
                                texture2d<float, access::sample> frame [[texture(0)]],
                                texture2d<float, access::sample> previous [[texture(1)]],
                                constant DisplayParams& p [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 u = in.uv;
    float2 f = float2(p.a * u.x + p.b * u.y + p.tx, p.c * u.x + p.d * u.y + p.ty);
    // 帧外面（按比例放进视图留下的边）是黑的
    float4 color = insideUnit(f) ? frame.sample(smp, f) : float4(0.0f, 0.0f, 0.0f, 1.0f);
    if (p.previousMix > 0.0f) {
        float2 g = float2(p.pa * u.x + p.pb * u.y + p.ptx, p.pc * u.x + p.pd * u.y + p.pty);
        float4 old = insideUnit(g) ? previous.sample(smp, g) : float4(0.0f, 0.0f, 0.0f, 1.0f);
        color = mix(color, old, p.previousMix);
    }
    return float4(color.rgb, 1.0f);
}
"""#
}
