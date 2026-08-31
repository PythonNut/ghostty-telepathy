//! Shader pipeline definitions for the Vulkan backend, mirroring
//! `opengl/shaders.zig`.
//!
//! REAL PIECE (shader translation proof): the pipeline table below
//! embeds SPIR-V binaries compiled from ghostty's cell shaders after
//! porting them to Vulkan-dialect GLSL (see ../shaders/vulkan/*.glsl
//! and skeleton/build-shaders.sh). The port required:
//!   - descriptor set layout: GL's separate binding namespaces
//!     (UBO binding=1, SSBO binding=1, samplers binding=0/1) collide in
//!     Vulkan, remapped to set 0 (UBO b0, SSBO b1) + set 1 (samplers)
//!   - sampler2DRect -> sampler2D + texelFetch (Vulkan has no
//!     rectangle textures; pixel-coordinate semantics preserved)
//!   - gl_VertexID -> gl_VertexIndex
//!   - dropped layout(origin_upper_left): Vulkan fragcoord is already
//!     top-left origin (matches, since ghostty's projection is
//!     top-left based; final Y flip is done with a negative viewport)
//! Every embedded binary is checked for the SPIR-V magic number at
//! pipeline init (see Pipeline.validateSpirv).
//!
//! STUB: post-process ("custom shader" / shadertoy) pipelines are not
//! supported and are skipped with a warning. The real implementation
//! is *simpler* than GL/Metal's: shadertoy.zig already produces SPIR-V
//! as its intermediate (`spirvFromGlsl`), so a Vulkan backend adds a
//! `.spirv` arm to `shadertoy.Target` and consumes it directly instead
//! of round-tripping through spirv-cross.
const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");

const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.vulkan);

/// Load a SPIR-V binary at comptime and sanity-check its magic number
/// so a bad build-prep step fails the build, not the runtime.
fn spirv(comptime path: []const u8) []const u8 {
    const data = @embedFile(path);
    comptime {
        if (data.len < 20 or data.len % 4 != 0)
            @compileError("invalid SPIR-V (size): " ++ path);
        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != 0x0723_0203)
            @compileError("invalid SPIR-V (magic): " ++ path);
    }
    // Re-store 4-byte aligned: VkShaderModuleCreateInfo.pCode wants
    // u32 words and @embedFile only guarantees byte alignment.
    const S = struct {
        const aligned: [data.len]u8 align(4) = data.*;
    };
    return &S.aligned;
}

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_spv = spirv("../shaders/vulkan/compiled/full_screen.v.spv"),
            .fragment_spv = spirv("../shaders/vulkan/compiled/bg_color.f.spv"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_spv = spirv("../shaders/vulkan/compiled/full_screen.v.spv"),
            .fragment_spv = spirv("../shaders/vulkan/compiled/cell_bg.f.spv"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_spv = spirv("../shaders/vulkan/compiled/cell_text.v.spv"),
            .fragment_spv = spirv("../shaders/vulkan/compiled/cell_text.f.spv"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_spv = spirv("../shaders/vulkan/compiled/image.v.spv"),
            .fragment_spv = spirv("../shaders/vulkan/compiled/image.f.spv"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_spv = spirv("../shaders/vulkan/compiled/bg_image.v.spv"),
            .fragment_spv = spirv("../shaders/vulkan/compiled/bg_image.f.spv"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_spv: []const u8,
    fragment_spv: []const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .vertex_spv = self.vertex_spv,
            .fragment_spv = self.fragment_spv,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// This contains the state for the shaders used by the Vulkan renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture.
    ///
    /// STUB: always empty; see file-level doc comment.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    pub fn init(
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        _ = alloc;

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline();
            initialized_pipelines += 1;
        }

        // STUB: custom (post-process) shaders are unsupported in the
        // skeleton. Honest behavior: warn and continue without them,
        // matching the GL backend's graceful degradation.
        if (post_shaders.len > 0) log.warn(
            "custom shaders are not supported by the vulkan skeleton, ignoring {d} shader(s)",
            .{post_shaders.len},
        );

        return .{
            .pipelines = pipelines,
            .post_pipelines = &.{},
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        _ = alloc;
        if (self.defunct) return;
        self.defunct = true;

        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
    }
};

// ---------------------------------------------------------------------------
// CPU-side data layouts shared with the shaders. These are IDENTICAL to the
// OpenGL backend's (opengl/shaders.zig): generic.zig fills these structs, and
// the std140/std430 layouts in the ported Vulkan GLSL match the originals.
// ---------------------------------------------------------------------------

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
