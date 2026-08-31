// Vulkan-dialect port of src/renderer/shaders/glsl/common.glsl
// (ghostty 1.3.1). Differences from the OpenGL original:
//
//  - #version 450 lives in each including shader (glslc's includer
//    requires #version to be the first line of the main file, unlike
//    ghostty's comptime include processor).
//  - Explicit descriptor sets. OpenGL has separate binding namespaces
//    for UBOs, SSBOs and samplers (the original uses UBO binding=1,
//    SSBO binding=1, samplers binding=0/1 simultaneously); in Vulkan
//    these all live in one namespace per set, so the layout is:
//        set 0, binding 0: Globals UBO
//        set 0, binding 1: bg cells SSBO (where used)
//        set 1, binding N: combined image samplers
//  - Member-level `uniform` qualifiers inside the block removed
//    (not legal in Vulkan GLSL).
//
// Everything else (field order/std140 layout, unpack helpers, color
// functions) is unchanged so the CPU-side `Uniforms` extern struct in
// vulkan/shaders.zig stays byte-identical to the GL/Metal backends.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
layout(set = 0, binding = 0, std140) uniform Globals {
    mat4 projection_matrix;
    vec2 screen_size;
    vec2 cell_size;
    uint grid_size_packed_2u16;
    vec4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint bools;
};

// Bools
const uint CURSOR_WIDE = 1u;
const uint USE_DISPLAY_P3 = 2u;
const uint USE_LINEAR_BLENDING = 4u;
const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
const uint EXTEND_LEFT = 1u;
const uint EXTEND_RIGHT = 2u;
const uint EXTEND_UP = 4u;
const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.

uvec4 unpack4u8(uint packed_value) {
    return uvec4(
        uint(packed_value >> 0) & uint(0xFF),
        uint(packed_value >> 8) & uint(0xFF),
        uint(packed_value >> 16) & uint(0xFF),
        uint(packed_value >> 24) & uint(0xFF)
    );
}

uvec2 unpack2u16(uint packed_value) {
    return uvec2(
        uint(packed_value >> 0) & uint(0xFFFF),
        uint(packed_value >> 16) & uint(0xFFFF)
    );
}

ivec2 unpack2i16(int packed_value) {
    return ivec2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color, in linear RGB space.
float luminance(vec3 color) {
    return dot(color, vec3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
float contrast_ratio(vec3 color1, vec3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio.
vec4 contrasted_color(float min_ratio, vec4 fg, vec4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(vec3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(vec3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return vec4(1.0);
        } else {
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    return fg;
}

// Converts a color from sRGB gamma encoding to linear.
vec4 linearize(vec4 srgb) {
    bvec3 cutoff = lessThanEqual(srgb.rgb, vec3(0.04045));
    vec3 higher = pow((srgb.rgb + vec3(0.055)) / vec3(1.055), vec3(2.4));
    vec3 lower = srgb.rgb / vec3(12.92);

    return vec4(mix(higher, lower, cutoff), srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
vec4 unlinearize(vec4 linear) {
    bvec3 cutoff = lessThanEqual(linear.rgb, vec3(0.0031308));
    vec3 higher = pow(linear.rgb, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear.rgb * vec3(12.92);

    return vec4(mix(higher, lower, cutoff), linear.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
vec4 load_color(
    uvec4 in_color,
    bool linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    vec4 color = vec4(in_color) / vec4(255.0f);

    // Linearize if necessary.
    if (linear) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}
