#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;
    float pointSize [[point_size]];
};

fragment float4 pointCloudFragmentShader(VertexOut in [[stage_in]],
                                         uint flashActive [[buffer(0)]]) {
    float gray = 0.8; // Or compute from depth, etc, for variety
    float3 color = float3(gray, gray, gray);

    if (flashActive == 1) {
        // Flash: bright color based on position or random
        float3 rainbow = float3(0.5 + 0.5 * sin(in.worldPos.x * 10 + in.worldPos.z * 10),
                                0.5 + 0.5 * sin(in.worldPos.x * 10 + 2.0f),
                                0.5 + 0.5 * cos(in.worldPos.z * 10));
        color = mix(color, rainbow, 0.8); // Mix for a vivid flash
    }
    return float4(color, 1.0);
}