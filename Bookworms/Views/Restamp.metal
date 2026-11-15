#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The weight of the ink in `color`: its coverage, a tenth more where the ink pooled, which the
// stamp's canvas prints darker than `inkPeak`, the stamp ink's brightest channel.
static float inkWeight(half4 color, float inkPeak) {
    if (color.a <= 0.0h) return 0.0;
    float peak = max(max(color.r, color.g), color.b) / color.a;
    float pooled = saturate((inkPeak / max(peak, 0.001) - 1.0) * 3.0);
    return color.a * (1.0 + 0.1 * pooled);
}

// A stamp's printed impression (`RestampEffect`) with its fresh ink short of soaking in by
// `bleed`, from 0 to 1. `position` is in points, `reach` is how far the heaviest fresh ink
// spreads as it soaks in, in points, and `ink` is the stamp's ink.
//
// Fresh ink lands thinner, the more so the heavier the ink around it, and soaks out to the
// impression at rest as `bleed` falls to 0: within `reach` times `bleed` times the ink's heft of
// its edges, a point keeps the mean of its own ink and the least ink at half and all of that
// distance, so the edge is soft, as ink wicks into paper. Faint ink barely moves. Fresh ink is a
// little darker while it is wet.
[[ stitchable ]] half4 restamp(
    float2 position, SwiftUI::Layer layer, float bleed, float reach, half4 ink)
{
    half4 color = layer.sample(position);
    if (color.a <= 0.0h || bleed <= 0.0) return color;
    float inkPeak = max(max(ink.r, ink.g), ink.b);
    // The heaviest ink within reach: the stroke's weight, even at its antialiased edge.
    float heaviest = inkWeight(color, inkPeak);
    for (int index = 0; index < 8; index++) {
        float angle = float(index) * M_PI_F / 4.0;
        float2 offset = reach * float2(cos(angle), sin(angle));
        heaviest = max(heaviest, inkWeight(layer.sample(position + offset), inkPeak));
    }
    float heft = saturate((heaviest - 0.4) / 0.7);
    float distance = reach * bleed * heft;
    half nearLeast = color.a;
    half farLeast = color.a;
    for (int index = 0; index < 8; index++) {
        float angle = (float(index) + 0.5) * M_PI_F / 4.0;
        float2 direction = float2(cos(angle), sin(angle));
        nearLeast = min(nearLeast, layer.sample(position + 0.5 * distance * direction).a);
        farLeast = min(farLeast, layer.sample(position + distance * direction).a);
    }
    color *= (color.a + nearLeast + farLeast) / (3.0h * color.a);
    color.rgb *= 1.0h - half(0.05 * bleed * heft);
    return color;
}
