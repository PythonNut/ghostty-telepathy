#version 450
#include "common.glsl"

// Port of glsl/image.v.glsl. Changes:
//  - Sampler moved to set 1, binding 0.
//  - gl_VertexID -> gl_VertexIndex.
//  - Explicit location on the tex_coord varying.
//  - Position z changed 1.0 -> 0.0: ortho2d negates z, so z=1 lands
//    on NDC z=-1. GL's clip volume includes it (-1 <= z <= 1); Vulkan
//    clips it (0 <= z <= 1) and discarded the whole quad, making all
//    kitty images invisible. z=0 matches cell_text.v.glsl (there is
//    no depth test; draw order layers the scene).

layout(set = 1, binding = 0) uniform sampler2D image;

layout(location = 0) in vec2 grid_pos;
layout(location = 1) in vec2 cell_offset;
layout(location = 2) in vec4 source_rect;
layout(location = 3) in vec2 dest_size;

layout(location = 0) out vec2 tex_coord;

void main() {
    int vid = gl_VertexIndex;

    // Triangle strip quad corner from the vertex index (see original).
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    tex_coord = source_rect.xy;
    tex_coord += source_rect.zw * corner;

    // Normalize the coordinates.
    tex_coord /= textureSize(image, 0);

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    vec2 image_pos = (cell_size * grid_pos) + cell_offset;
    image_pos += dest_size * corner;

    gl_Position = projection_matrix * vec4(image_pos.xy, 0.0, 1.0);
}
