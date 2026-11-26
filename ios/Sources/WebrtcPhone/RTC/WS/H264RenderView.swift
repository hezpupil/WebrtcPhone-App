import SwiftUI
import MetalKit
import Metal
import CoreVideo

/// H.264 解码帧 Metal 渲染器（WS 模式）。
/// VideoToolbox 输出 BGRA CVPixelBuffer，经 CVMetalTextureCache 转 MTLTexture，
/// 等比居中（letterbox 黑边）绘制。display() 可在任意线程调用（内部加锁），
/// MTKView 由新帧驱动（isPaused + setNeedsDisplay），无帧时零 GPU 开销。
final class H264FrameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };
    // 顶点 buffer: float4(x,y,u,v) ×4，triangle strip TL/TR/BL/BR
    vertex VOut vs_main(uint vid [[vertex_id]],
                        constant float4 *quad [[buffer(0)]]) {
        VOut o;
        o.pos = float4(quad[vid].xy, 0.0, 1.0);
        o.uv = quad[vid].zw;
        return o;
    }
    fragment float4 fs_main(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.uv);
    }
    """

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let vsFn = lib.makeFunction(name: "vs_main")!
            let fsFn = lib.makeFunction(name: "fs_main")!
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vsFn
            desc.fragmentFunction = fsFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Trail.mark("h264r:pipeline-failed \(error.localizedDescription)")
            return nil
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        super.init()
    }

    /// 解码线程回调：只保留最新帧（解码快于渲染时自然丢帧，保持低延迟）
    func display(_ pb: CVPixelBuffer) {
        lock.lock()
        pixelBuffer = pb
        lock.unlock()
    }

    func clear() {
        lock.lock()
        pixelBuffer = nil
        lock.unlock()
    }

    private func takeBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pixelBuffer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pb = takeBuffer(),
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        // CVPixelBuffer → MTLTexture（texture cache 管理生命周期，绘制完释放）
        var texRef: CVMetalTexture?
        guard let cache = textureCache,
              CVMetalTextureCacheCreateTextureFromImage(
                  kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm,
                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &texRef) == kCVReturnSuccess,
              let texRef, let tex = CVMetalTextureGetTexture(texRef) else { return }

        // aspect-fit 顶点（TL/TR/BL/BR triangle strip），UV y=0 在顶部（H.264 首行在上）
        let vw = CGFloat(drawable.texture.width), vh = CGFloat(drawable.texture.height)
        let tw = CGFloat(tex.width), th = CGFloat(tex.height)
        var qw: CGFloat = 2, qh: CGFloat = 2
        if vw > 0, vh > 0, tw > 0, th > 0 {
            let va = vw / vh, ta = tw / th
            if va > ta { qh = 2 * ta / va } else { qw = 2 * va / ta }
        }
        // Metal UV 原点在左上：uv(0,0) → 视口顶部 (y=+1)
        let quad: [SIMD4<Float>] = [
            SIMD4(Float(-qw), Float(1), 0, 0),
            SIMD4(Float(qw), Float(1), 1, 0),
            SIMD4(Float(-qw), Float(-1), 0, 1),
            SIMD4(Float(qw), Float(-1), 1, 1),
        ]
        guard let vbuf = device.makeBuffer(bytes: quad, length: MemoryLayout<SIMD4<Float>>.stride * 4) else { return }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// SwiftUI 包装：WS 模式视频画面（替代 WebRTC 的 RTCMTLVideoView）
struct H264RenderView: UIViewRepresentable {
    let renderer: H264FrameRenderer

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.delegate = renderer
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.colorPixelFormat = .bgra8Unorm
        v.contentMode = .scaleAspectFit
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {}
}
