#include <metal_stdlib>
using namespace metal;

struct GVDatamoshUniforms {
    float4 motion; // persistence, displacement strength, angle, velocity decay
    float4 timing; // seconds per frame, simulation clock, residual injection, release ramp
    float4 layout; // width, height, macroblock pixels, output blend
    float4 touch; // position, velocity
    uint4 flags; // seed, freeze, touch active, reserved
};

kernel void gvDatamoshSource(texture2d<half, access::sample> input [[texture(0)]],
                             texture2d<half, access::read_write> reference [[texture(1)]],
                             constant GVDatamoshUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= reference.get_width() || p.y >= reference.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(p) + 0.5) / float2(reference.get_width(), reference.get_height());
    half4 incoming = input.sample(s, uv);
    reference.write(u.flags.x ? incoming : mix(reference.read(p), incoming, half(u.timing.w)), p);
}

kernel void gvDatamoshVelocity(texture2d<half, access::sample> previous [[texture(0)]],
                               texture2d<half, access::write> next [[texture(1)]],
                               constant GVDatamoshUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= next.get_width() || p.y >= next.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 grid = float2(next.get_width(), next.get_height());
    float2 uv = (float2(p) + 0.5) / grid;
    float dt = u.timing.x;
    float2 velocity = 0;
    if (!u.flags.x) {
        float2 old = float2(previous.sample(s, uv).xy);
        float2 upstream = uv - old * dt / u.layout.xy;
        velocity = float2(previous.sample(s, upstream).xy);
        float2 neighbors = float2(previous.sample(s, upstream + float2(1, 0) / grid).xy)
                         + float2(previous.sample(s, upstream - float2(1, 0) / grid).xy)
                         + float2(previous.sample(s, upstream + float2(0, 1) / grid).xy)
                         + float2(previous.sample(s, upstream - float2(0, 1) / grid).xy);
        velocity = mix(velocity, neighbors * 0.25, 1.0 - exp(-2.4 * dt));
    }
    float2 direction = float2(cos(u.motion.z), sin(u.motion.z));
    float2 normal = float2(-direction.y, direction.x);
    // Smooth, low-frequency shear keeps neighboring blocks coherent; no per-frame random jumps.
    float phase = dot(uv, normal) * 13.0 + dot(uv, direction) * 4.0;
    float wave = sin(phase + u.timing.y * 0.37);
    float2 drive = direction * (0.7 + 0.3 * sin(phase * 0.63 - u.timing.y * 0.21))
                 + normal * wave * 0.38;
    float decay = 0.65 + u.motion.w * 5.0;
    velocity *= exp(-decay * dt);
    velocity += drive * (90.0 * u.motion.y) * (1.0 - exp(-decay * dt)) / decay;
    if (u.flags.z) {
        float2 distance = (uv - u.touch.xy) * float2(u.layout.x / u.layout.y, 1);
        float influence = exp(-dot(distance, distance) / 0.035);
        float2 finger = clamp(u.touch.zw * u.layout.xy * 0.12, -180.0, 180.0);
        velocity = mix(velocity, finger, influence * (1.0 - exp(-8.0 * dt)));
    }
    float speed = length(velocity);
    velocity *= min(1.0, 180.0 / max(speed, 0.0001));
    next.write(half4(half2(velocity), 0, 0), p);
}

kernel void gvDatamoshFeedback(texture2d<half, access::read> reference [[texture(0)]],
                               texture2d<half, access::sample> previous [[texture(1)]],
                               texture2d<half, access::read> velocity [[texture(2)]],
                               texture2d<half, access::write> next [[texture(3)]],
                               texture2d<half, access::write> output [[texture(4)]],
                               constant GVDatamoshUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::mirrored_repeat, filter::linear);
    half4 source = reference.read(p);
    half4 result = source;
    if (!u.flags.x) {
        if (u.flags.y) {
            result = previous.read(p);
        } else {
            uint2 cell = min(p / uint(u.layout.z), uint2(velocity.get_width() - 1, velocity.get_height() - 1));
            float2 motion = float2(velocity.read(cell).xy);
            float2 uv = (float2(p) + 0.5 - motion * u.timing.x) / u.layout.xy;
            half4 transported = previous.sample(s, uv);
            float memory = pow(u.motion.x * (1.0 - u.timing.z), u.timing.x * 60.0);
            result = mix(source, transported, half(memory));
        }
    }
    result.a = 1;
    next.write(result, p);
    output.write(mix(source, result, half(u.layout.w)), p);
}
