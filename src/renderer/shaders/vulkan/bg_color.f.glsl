#version 450
#include "common.glsl"

// Port of glsl/bg_color.f.glsl (no changes beyond common.glsl's
// descriptor layout).

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    out_FragColor = load_color(
            unpack4u8(bg_color_packed_4u8),
            use_linear_blending
        );
}
