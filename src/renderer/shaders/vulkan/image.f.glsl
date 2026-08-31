#version 450
#include "common.glsl"

// Port of glsl/image.f.glsl. Changes: sampler set/binding, explicit
// varying location.

layout(set = 1, binding = 0) uniform sampler2D image;

layout(location = 0) in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 rgba = texture(image, tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= vec3(rgba.a);

    out_FragColor = rgba;
}
