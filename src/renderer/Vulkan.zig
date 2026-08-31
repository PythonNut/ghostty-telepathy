//! Graphics API wrapper for Vulkan with Android swapchain presentation.
//!
//! Rendering: a real VkDevice, Ghostty's SPIR-V pipelines, host-visible
//! buffers, and staged texture uploads. Recording and submission happen on
//! Ghostty's renderer thread.
//!
//! Presentation: each frame renders directly into an image acquired from an
//! Android VkSwapchainKHR; there is no offscreen copy on the terminal path.
//!
//! Synchronization: two reusable frame slots permit one frame of CPU/GPU
//! overlap. A single completion worker waits on their fences and releases
//! Ghostty's corresponding generic frame states. This bounds queued work and
//! avoids blocking the renderer thread after every submission.
pub const Vulkan = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const shadertoy = @import("shadertoy.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Vulkan);
const telemetrypkg = @import("vulkan/Telemetry.zig");

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

/// Match Ghostty's logical frame-state rotation to the Vulkan frame slots.
pub const swap_chain_count = vk.frame_count;

const log = std.log.scoped(.vulkan);

pub const Completion = struct {
    renderer: *Renderer,
    slot: *vk.FrameSlot,
    health: rendererpkg.Health,
    submitted: bool,
    submitted_at_ns: u64 = 0,
    telemetry_recorded: bool = false,
    sync: ?*std.Thread.Semaphore = null,
};

/// One waiter is sufficient because all submissions share one ordered queue.
/// Its fixed two-entry queue mirrors the two generic and Vulkan frame slots.
pub const CompletionWorker = struct {
    alloc: Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    entries: [vk.frame_count]Completion = undefined,
    head: usize = 0,
    count: usize = 0,
    stopping: bool = false,
    thread: ?std.Thread = null,

    fn init(alloc: Allocator) !*CompletionWorker {
        const self = try alloc.create(CompletionWorker);
        self.* = .{ .alloc = alloc };
        errdefer alloc.destroy(self);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn deinit(self: *CompletionWorker) void {
        self.mutex.lock();
        self.stopping = true;
        self.condition.signal();
        self.mutex.unlock();
        self.thread.?.join();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn enqueue(self: *CompletionWorker, completion: Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.count < self.entries.len);
        const tail = (self.head + self.count) % self.entries.len;
        var entry = completion;
        self.count += 1;
        if (entry.submitted) {
            entry.telemetry_recorded = entry.renderer.api.telemetry.frameSubmitted(self.count);
        }
        self.entries[tail] = entry;
        self.condition.signal();
    }

    fn run(self: *CompletionWorker) void {
        while (true) {
            self.mutex.lock();
            while (self.count == 0 and !self.stopping) {
                self.condition.wait(&self.mutex);
            }
            if (self.count == 0 and self.stopping) {
                self.mutex.unlock();
                return;
            }
            var completion = self.entries[self.head];
            self.head = (self.head + 1) % self.entries.len;
            self.count -= 1;
            self.mutex.unlock();

            var completed_at_ns: u64 = 0;
            if (completion.submitted) {
                completed_at_ns = completion.slot.waitAndCleanup() catch |err| completed: {
                    log.err("frame completion wait failed err={}", .{err});
                    completion.health = .unhealthy;
                    break :completed 0;
                };
            } else {
                completion.slot.discard();
            }
            self.mutex.lock();
            const completion_queue_depth = self.count;
            self.mutex.unlock();
            const completion_duration_ns = if (completion.telemetry_recorded) duration: {
                break :duration if (completion.submitted_at_ns == 0 or
                    completed_at_ns == 0 or
                    completed_at_ns < completion.submitted_at_ns)
                    0
                else
                    completed_at_ns - completion.submitted_at_ns;
            } else 0;
            completion.renderer.api.telemetry.frameCompleted(
                completion_duration_ns,
                completion_queue_depth,
                completion.telemetry_recorded,
            );
            completion.renderer.frameCompleted(completion.health);
            if (completion.sync) |semaphore| semaphore.post();
        }
    }
};

alloc: Allocator,

/// The shared (refcounted) device context.
device: *vk.Device,

/// Exactly two per-renderer command/fence/descriptor slots.
frames: vk.FrameSet,

/// Asynchronous fence waiter for the bounded frame slots.
completion: *CompletionWorker,

/// Android surface and swapchain state owned by this renderer instance.
presentation: vk.Surface,

/// Alpha blending mode (written back by generic.zig on config change).
blending: configpkg.Config.AlphaBlending,

/// Current surface size in pixels, updated by the Android host on resize.
size: struct { width: u32, height: u32 },

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Detailed instrumentation enabled only by Telepathy's renderer harness.
telemetry: telemetrypkg.Telemetry = .{},
device_telemetry_enabled: bool = false,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    const window: *vk.c.ANativeWindow = @ptrCast(@alignCast(opts.rt_surface));
    const device = try vk.deviceRef(alloc);
    errdefer vk.deviceUnref();
    var presentation = try vk.Surface.init(
        alloc,
        device,
        window,
        opts.size.screen.width,
        opts.size.screen.height,
    );
    errdefer presentation.deinit();
    var frames = try vk.FrameSet.init(device);
    errdefer frames.deinit();
    const completion = try CompletionWorker.init(alloc);
    errdefer completion.deinit();
    return .{
        .alloc = alloc,
        .device = device,
        .frames = frames,
        .completion = completion,
        .presentation = presentation,
        .blending = opts.config.blending,
        .size = .{
            .width = opts.size.screen.width,
            .height = opts.size.screen.height,
        },
    };
}

pub fn deinit(self: *Vulkan) void {
    self.completion.deinit();
    if (self.device_telemetry_enabled) vk.deviceTelemetryDisable();
    self.presentation.deinit();
    self.frames.deinit();
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

pub const TelemetrySnapshot = struct {
    renderer: telemetrypkg.Snapshot,
    device: telemetrypkg.DeviceSnapshot,
    display_timing_supported: bool,
};

pub fn setTelemetryEnabled(self: *Vulkan, enabled: bool) void {
    if (self.telemetry.enabled() == enabled) return;
    if (enabled) {
        vk.deviceTelemetryEnable();
        self.device_telemetry_enabled = true;
        self.telemetry.setEnabled(true);
    } else {
        self.telemetry.setEnabled(false);
        if (self.device_telemetry_enabled) {
            vk.deviceTelemetryDisable();
            self.device_telemetry_enabled = false;
        }
    }
}

pub fn telemetrySnapshot(self: *Vulkan) TelemetrySnapshot {
    if (self.presentation.displayTimingSupported()) {
        self.presentation.collectPastPresentationTimings(&self.telemetry);
    }
    return .{
        .renderer = self.telemetry.snapshot(),
        .device = vk.deviceTelemetrySnapshot(),
        .display_timing_supported = self.presentation.displayTimingSupported(),
    };
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
    try self.presentation.present(&self.telemetry);
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
    const slot = self.frames.next();
    var frame = try Frame.begin(.{ .slot = slot }, renderer, target);
    errdefer frame.cancel();
    const acquire_started_ns = if (self.telemetry.enabled()) vk.monotonicNanos() else 0;
    try self.presentation.acquire(target, slot.image_available);
    const acquired_ns = if (acquire_started_ns == 0) 0 else vk.monotonicNanos();
    if (acquire_started_ns != 0 and acquired_ns >= acquire_started_ns) {
        self.telemetry.recordAcquire(acquired_ns - acquire_started_ns);
    }
    frame.encoding_started_ns = acquired_ns;
    return frame;
}
