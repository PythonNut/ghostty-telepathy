#version 450
#include "common.glsl"

// Port of glsl/cell_text.f.glsl. Changes:
//  - sampler2DRect -> sampler2D + texelFetch (Vulkan has no rectangle
//    textures; tex_coord is in pixels and the atlas is sampled with
//    nearest filtering, so texelFetch preserves the exact semantics).
//  - Samplers moved to set 1 (see common.glsl for the layout).
//  - Explicit location on the input interface block.

layout(set = 1, binding = 0) uniform sampler2D atlas_grayscale;
layout(set = 1, binding = 1) uniform sampler2D atlas_color;

layout(location = 0) in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    switch (in_data.atlas) {
        default:
        case ATLAS_GRAYSCALE:
        {
            // Our input color is always linear.
            vec4 color = in_data.color;

            // If we're not doing linear blending, then we need to
            // re-apply the gamma encoding to our color manually.
            if (!use_linear_blending) {
                color.rgb /= vec3(color.a);
                color = unlinearize(color);
                color.rgb *= vec3(color.a);
            }

            // Fetch our alpha mask for this pixel.
            float a = texelFetch(atlas_grayscale, ivec2(in_data.tex_coord), 0).r;

            // Linear blending weight correction corrects the alpha value to
            // produce blending results which match gamma-incorrect blending.
            if (use_linear_correction) {
                vec4 bg = in_data.bg_color;
                float fg_l = luminance(color.rgb);
                float bg_l = luminance(bg.rgb);
                if (abs(fg_l - bg_l) > 0.001) {
                    float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                    a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
                }
            }

            // Multiply our whole color by the alpha mask (premultiplied).
            color *= a;

            out_FragColor = color;
            return;
        }

        case ATLAS_COLOR:
        {
            // For now, we assume that color glyphs
            // are already premultiplied linear colors.
            vec4 color = texelFetch(atlas_color, ivec2(in_data.tex_coord), 0);

            // If we are doing linear blending, we can return this right away.
            if (use_linear_blending) {
                out_FragColor = color;
                return;
            }

            // Otherwise we need to unlinearize the color.
            color.rgb /= vec3(color.a);
            color = unlinearize(color);
            color.rgb *= vec3(color.a);

            out_FragColor = color;
            return;
        }
    }
}
