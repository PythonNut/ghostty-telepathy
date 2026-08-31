#version 450
#include "common.glsl"

// Port of glsl/bg_image.v.glsl. Changes:
//  - Sampler moved to set 1, binding 0.
//  - gl_VertexID -> gl_VertexIndex.
//  - Explicit locations on all varyings.
//  - Dropped the `vec2 screen_size = screen_size;` self-shadowing
//    redeclaration (uses the UBO member directly).

layout(set = 1, binding = 0) uniform sampler2D image;

layout(location = 0) in float in_opacity;
layout(location = 1) in uint info;

// 4 bits of info.
const uint BG_IMAGE_POSITION = 15u;
const uint BG_IMAGE_TL = 0u;
const uint BG_IMAGE_TC = 1u;
const uint BG_IMAGE_TR = 2u;
const uint BG_IMAGE_ML = 3u;
const uint BG_IMAGE_MC = 4u;
const uint BG_IMAGE_MR = 5u;
const uint BG_IMAGE_BL = 6u;
const uint BG_IMAGE_BC = 7u;
const uint BG_IMAGE_BR = 8u;

// 2 bits of info shifted 4.
const uint BG_IMAGE_FIT = 3u << 4;
const uint BG_IMAGE_CONTAIN = 0u << 4;
const uint BG_IMAGE_COVER = 1u << 4;
const uint BG_IMAGE_STRETCH = 2u << 4;
const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of info shifted 6.
const uint BG_IMAGE_REPEAT = 1u << 6;

layout(location = 0) flat out vec4 bg_color;
layout(location = 1) flat out vec2 offset;
layout(location = 2) flat out vec2 scale;
layout(location = 3) flat out float opacity;
layout(location = 4) flat out uint repeat;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 position;
    position.x = (gl_VertexIndex == 2) ? 3.0 : -1.0;
    position.y = (gl_VertexIndex == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;

    // Single triangle is clipped to viewport (see full_screen.v.glsl).
    gl_Position = position;

    opacity = in_opacity;

    repeat = info & BG_IMAGE_REPEAT;

    vec2 tex_size = textureSize(image, 0);

    vec2 dest_size = tex_size;
    switch (info & BG_IMAGE_FIT) {
        case BG_IMAGE_CONTAIN: {
            float s = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
            dest_size = tex_size * s;
        } break;

        case BG_IMAGE_COVER: {
            float s = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
            dest_size = tex_size * s;
        } break;

        case BG_IMAGE_STRETCH: {
            dest_size = screen_size;
        } break;

        case BG_IMAGE_NO_FIT: {
            dest_size = tex_size;
        } break;
    }

    vec2 start = vec2(0.0);
    vec2 mid = (screen_size - dest_size) / vec2(2.0);
    vec2 end = screen_size - dest_size;

    vec2 dest_offset = mid;
    switch (info & BG_IMAGE_POSITION) {
        case BG_IMAGE_TL: {
            dest_offset = vec2(start.x, start.y);
        } break;
        case BG_IMAGE_TC: {
            dest_offset = vec2(mid.x, start.y);
        } break;
        case BG_IMAGE_TR: {
            dest_offset = vec2(end.x, start.y);
        } break;
        case BG_IMAGE_ML: {
            dest_offset = vec2(start.x, mid.y);
        } break;
        case BG_IMAGE_MC: {
            dest_offset = vec2(mid.x, mid.y);
        } break;
        case BG_IMAGE_MR: {
            dest_offset = vec2(end.x, mid.y);
        } break;
        case BG_IMAGE_BL: {
            dest_offset = vec2(start.x, end.y);
        } break;
        case BG_IMAGE_BC: {
            dest_offset = vec2(mid.x, end.y);
        } break;
        case BG_IMAGE_BR: {
            dest_offset = vec2(end.x, end.y);
        } break;
    }

    offset = dest_offset;
    scale = tex_size / dest_size;

    // We load a fully opaque version of the bg color and combine it with
    // the alpha separately, because we need these as separate values in
    // the fragment shader.
    uvec4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    bg_color = vec4(load_color(
                uvec4(u_bg_color.rgb, 255),
                use_linear_blending
            ).rgb, float(u_bg_color.a) / 255.0);
}
