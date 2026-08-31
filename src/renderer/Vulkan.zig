//! Graphics API wrapper for Vulkan with dmabuf presentation.
//!
//! Rendering: real VkDevice (v3dv on the Pi CM5), the ported SPIR-V
//! pipelines, host-visible buffers, staged texture uploads. All GPU
//! work happens on the GTK main thread (must_draw_from_app_thread).
//!
//! Presentation: each frame renders into an offscreen VkImage whose
//! memory is exported as a dmabuf (VK_EXT_external_memory_dma_buf,
//! LINEAR layout — see vulkan/Target.zig). present() hands the fd to
//! the GTK apprt, which wraps it in a GdkDmabufTexture and sets it as
//! the paintable of the surface's GtkPicture. On Wayland GSK can pass
//! the dmabuf through to the compositor without a copy.
//!
//! Synchronization: the frame's command buffer is fence-waited before
//! present (GL-backend-equivalent of glFinish), so the consumer never
//! observes a partially rendered buffer. swap_chain_count = 3 keeps
//! previously presented dmabufs alive while the compositor uses them.
pub const Vulkan = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const shadertoy = @import("shadertoy.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Vulkan);

pub const GraphicsAPI = Vulkan;
pub const Target = @import("vulkan/Target.zig");
pub const Frame = @import("vulkan/Frame.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("vulkan/Sampler.zig");
pub const Texture = @import("vulkan/Texture.zig");
pub const shaders = @import("vulkan/shaders.zig");
const vk = @import("vulkan/vk.zig");

/// Custom (shadertoy) shaders are not supported by this experiment;
/// the decl must exist for generic.zig. A real implementation would
/// add a `.spirv` arm to shadertoy.Target and consume shadertoy.zig's
/// SPIR-V intermediate directly.
pub const custom_shader_target: shadertoy.Target = .glsl;

/// Vulkan's fragcoord origin is top-left (+Y down), like Metal.
pub const custom_shader_y_is_down = true;

/// The Telepathy artifact is embedded without Ghostty's desktop apprt.
pub const standalone = true;

/// Number of offscreen targets rotated by the generic renderer. Three
/// (like Metal) so the compositor can still be reading frame N-1/N-2's
/// dmabuf while we render frame N.
pub const swap_chain_count = 3;

const log = std.log.scoped(.vulkan);

alloc: Allocator,

/// The shared (refcounted) device context.
device: *vk.Device,

/// Android surface and swapchain state owned by this renderer instance.
presentation: vk.Surface,

/// Alpha blending mode (written back by generic.zig on config change).
blending: configpkg.Config.AlphaBlending,

/// Current surface size in pixels; updated by the GTK apprt on widget
/// resize via `setSurfaceSize` (both on the main thread).
size: struct { width: u32, height: u32 },

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    const window: *vk.c.ANativeWindow = @ptrCast(@alignCast(opts.rt_surface));
    const device = try vk.deviceRef(alloc);
    errdefer vk.deviceUnref();
    const presentation = try vk.Surface.init(
        alloc,
        device,
        window,
        opts.size.screen.width,
        opts.size.screen.height,
    );
    return .{
        .alloc = alloc,
        .device = device,
        .presentation = presentation,
        .blending = opts.config.blending,
        .size = .{
            .width = opts.size.screen.width,
            .height = opts.size.screen.height,
        },
    };
}

pub fn deinit(self: *Vulkan) void {
    self.presentation.deinit();
    vk.deviceUnref();
    self.* = undefined;
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *anyopaque) !void {
    _ = surface;
    // Vulkan needs no context made current; device creation happens in
    // init (and fails there with a clear log if no ICD/device exists).
}

/// Called just prior to spinning up the renderer thread; store the
/// apprt surface used for presentation.
pub fn finalizeSurfaceInit(self: *Vulkan, surface: *anyopaque) !void {
    _ = self;
    _ = surface;
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Vulkan, surface: *anyopaque) !void {
    _ = self;
    _ = surface;
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Vulkan) void {
    _ = self;
}

/// Called by the GTK apprt when the widget is realized.
pub fn displayRealized(self: *const Vulkan) void {
    _ = self;
}

/// Called by the GTK apprt when the widget is unrealized.
pub fn displayUnrealized(self: *const Vulkan) void {
    _ = self;
}

/// Called by the GTK apprt when the render widget is resized.
/// Width/height are in pixels.
pub fn setSurfaceSize(self: *Vulkan, width: u32, height: u32) void {
    self.size = .{ .width = width, .height = height };
    self.presentation.resize(width, height);
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *Vulkan) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *Vulkan) void {
    _ = self;
}

pub fn initShaders(
    self: *const Vulkan,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    return .{ .width = self.size.width, .height = self.size.height };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    return Target.init(.{
        .width = width,
        .height = height,
        .srgb = self.blending.isLinear(),
    });
}

/// Present the provided target: dup the exported dmabuf fd and hand it
/// to the GTK apprt (main thread) to wrap in a GdkDmabufTexture.
pub fn present(self: *Vulkan, target: Target) !void {
    try self.presentation.present();
    self.last_target = target;
}

/// Present the last presented target again.
///
/// Unlike the GL backend (whose GLArea framebuffer must be re-blitted
/// every render cycle), the GtkPicture keeps displaying the last
/// GdkDmabufTexture we handed it, and the underlying dmabuf still
/// holds the last rendered frame. Nothing to do.
pub fn presentLastTarget(self: *Vulkan) !void {
    _ = self;
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .vertex };
}

pub inline fn instanceBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .vertex };
}

pub inline fn uniformBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .uniform };
}

/// Cell text (fg) instances are read as vertex data; bg cells are
/// read from a storage buffer in the shaders.
pub inline fn fgBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .vertex };
}

pub inline fn bgBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .storage };
}

pub inline fn imageBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .vertex };
}

pub inline fn bgImageBufferOptions(self: Vulkan) bufferpkg.Options {
    _ = self;
    return .{ .usage = .vertex };
}

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Vulkan) Texture.Options {
    return .{
        .format = .rgba,
        .srgb = self.blending.isLinear(),
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: Vulkan) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toTextureFormat(self: ImageTextureFormat) Texture.Format {
        return switch (self) {
            .gray => .gray,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Vulkan,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toTextureFormat(),
        .srgb = srgb,
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
///
/// NOTE: the GL backend uses GL_TEXTURE_RECTANGLE here; Vulkan has no
/// rectangle textures, so the ported cell_text shaders use texelFetch
/// on a regular image, preserving pixel-coordinate addressing.
pub fn initAtlasTexture(
    self: *const Vulkan,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: Texture.Format, const srgb: bool = switch (atlas.format) {
        .grayscale => .{ .gray, false },
        .bgra => .{ .bgra, true },
        else => @panic("unsupported atlas format for Vulkan texture"),
    };

    return try Texture.init(
        .{
            .format = format,
            .srgb = srgb,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *Vulkan,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    try self.presentation.acquire(target);
    return try Frame.begin(.{}, renderer, target);
}
