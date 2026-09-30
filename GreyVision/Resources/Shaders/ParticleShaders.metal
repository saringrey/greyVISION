//
//  ParticleShaders.metal
//  greyvision
//
//  GPU side of the particle family (STATIC / EMBER / DUST / GLITCH).
//
//  The CPU simulation lives in GreyVision/Engine/Particles/GVParticleEngine.swift
//  and uploads one vertex per alive particle each frame. This file only draws
//  them: point sprites, additive blend, premultiplied colors.
//
//  Layout contracts (byte-exact mirrors, keep in sync):
//    GVParticleVertex   <-> GVParticleVertexData   (32 bytes)
//    GVParticleUniforms <-> GVParticleUniforms     (16 bytes)
//
//  Swift entry-point names: "gvParticleVertex", "gvParticleFragment".
//  They are looked up with `library.makeFunction(name:)` in
//  GVParticleOverlayEffect.prepare(_:) — renaming either side breaks the
//  effect at runtime (fail-closed: zero particles, no crash).
//

#include <metal_stdlib>
using namespace metal;

// Must match GVParticleVertexData in GVParticleEngine.swift.
struct GVParticleVertex {
    float2 position;  // pixels, top-left origin
    float  size;      // diameter, pixels
    float  shape;     // 0 = soft disc, 1 = hard square
    float4 color;     // premultiplied linear rgb, alpha in .w (unused)
};

// Must match GVParticleUniforms in GVParticleOverlayEffect.swift.
struct GVParticleUniforms {
    float2 viewportSize;
    float  globalAlpha;
    float  pointScale;
};

struct GVParticleVaryings {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 color;
    float  shape;
};

vertex GVParticleVaryings gvParticleVertex(
    const device GVParticleVertex *vertices [[buffer(0)]],
    constant GVParticleUniforms &uniforms    [[buffer(1)]],
    uint vertexID [[vertex_id]])
{
    const GVParticleVertex v = vertices[vertexID];
    GVParticleVaryings out;

    // Pixels (top-left origin) -> Metal clip space (NDC, y-up).
    float2 clip = (v.position / uniforms.viewportSize) * 2.0 - 1.0;
    clip.y = -clip.y;
    out.position = float4(clip, 0.0, 1.0);

    out.pointSize = max(v.size * uniforms.pointScale, 1.0);
    out.color = float4(v.color.rgb * uniforms.globalAlpha, 1.0);
    out.shape = v.shape;
    return out;
}

fragment float4 gvParticleFragment(
    GVParticleVaryings in [[stage_in]],
    float2 pointCoord [[point_coord]])
{
    const float2 centered = pointCoord - 0.5;
    float mask;
    if (in.shape > 0.5) {
        // Hard square for glitch shards. A 1px feathered edge avoids shimmer
        // when shards teleport between frames.
        const float edge = max(abs(centered.x), abs(centered.y)) * 2.0;
        mask = 1.0 - smoothstep(0.82, 1.0, edge);
    } else {
        // Soft disc with a hot core for static / ember / dust.
        const float r = length(centered) * 2.0;
        mask = clamp(1.0 - r, 0.0, 1.0);
        mask *= mask;
    }
    // Alpha channel stays 0: with additive blending (.one, .one) the
    // destination alpha is preserved exactly, only rgb accumulates.
    return float4(in.color.rgb * mask, 0.0);
}
