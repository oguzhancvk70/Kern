import Metal
import MetalKit
import simd

// Shaders.metal ile aynı yerleşim (stride 64)
struct Instance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var uv: SIMD2<Float> = .zero
    var uvSize: SIMD2<Float> = .zero
    var color: SIMD4<Float>
    var mode: UInt32 = 0
}

extension Instance {
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: SIMD4<Float>) -> Instance {
        Instance(pos: SIMD2(Float(x), Float(y)), size: SIMD2(Float(w), Float(h)), color: color)
    }
}

final class Renderer {
    let device: MTLDevice
    let atlas: GlyphAtlas
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let atlas = GlyphAtlas(device: device) else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) } catch {
            NSLog("Kern shader: \(error)")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.atlas = atlas
        self.queue = queue
        self.pipeline = pipeline
    }

    func render(_ instances: [Instance], in view: MTKView, clear: SIMD4<Float>) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: Double(clear.w))
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !instances.isEmpty,
           let buffer = device.makeBuffer(bytes: instances, length: MemoryLayout<Instance>.stride * instances.count) {
            var viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// mode: 0 düz renk, 1 tek renk glyph (alpha maskesi), 2 renkli glyph (emoji)
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float2 pos;
    float2 size;
    float2 uv;
    float2 uvSize;
    float4 color;
    uint mode;
};

struct Out {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint mode [[flat]];
};

vertex Out vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                 constant Instance *inst [[buffer(0)]],
                 constant float2 &viewport [[buffer(1)]]) {
    Instance i = inst[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = i.pos + corner * i.size;
    Out o;
    o.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
    o.uv = i.uv + corner * i.uvSize;
    o.color = i.color;
    o.mode = i.mode;
    return o;
}

fragment float4 fmain(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    if (in.mode == 0) { return in.color; }
    float4 t = atlas.sample(s, in.uv);
    if (in.mode == 1) { return in.color * t.a; }
    return t;
}
"""
