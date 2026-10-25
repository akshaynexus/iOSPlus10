// SPDX-License-Identifier: MIT
// Copied from Chlorophyll (ry-diffusion/Chlorophyll 787338f, test/bg_render.metal), MIT: see LICENSE.Chlorophyll here.
// NegroniMetal changes: only the two functions layerprobe uses (bg_vs, bg_fs_color). scripts/metal/build.sh compiles this for
// iOS 16 into /usr/local/share/negronimetal/layerprobe.metallib (needs Xcode's metal compiler; skipped without it).
//
// Render test shaders for the BGMTLDevice probe: a coloured triangle and a textured quad.
#include <metal_stdlib>
using namespace metal;

struct V { float4 pos [[position]]; float4 color; float2 uv; };

// positions and colours from buffer(0): float4 pos, float4 color per vertex (stride 32)
vertex V bg_vs(uint vid [[vertex_id]], device const float4 *data [[buffer(0)]])
{
   V v;
   v.pos = data[vid * 2];
   v.color = data[vid * 2 + 1];
   v.uv = v.pos.xy * 0.5 + 0.5;
   return v;
}

fragment float4 bg_fs_color(V in [[stage_in]]) { return in.color; }
