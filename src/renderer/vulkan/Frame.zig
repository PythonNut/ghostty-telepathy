//! Wrapper for handling frames, mirroring `opengl/Frame.zig`.
//!
//! A frame records into the device's frame command buffer, submits it,
//! queues presentation, and then waits on its fence before returning —
//! the Vulkan equivalent of the GL backend's glFinish-before-present.
//! This is a deliberate, documented compromise: correctness first
//! (the dmabuf consumer must never observe an in-flight render), at
//! the cost of serializing CPU and GPU per frame. The generic
//! renderer's swap chain (swap_chain_count targets) still lets the
//! compositor hold previous frames' dmabufs while we render new ones.
const Self = @This();

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const Vulkan = @import("../Vulkan.zig");
const Renderer = @import("../generic.zig").Renderer(Vulkan);
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.vulkan);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,
cmd: c.VkCommandBuffer,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) vk.Error!Self {
    _ = opts;
    const d = vk.dev();

    // Reset per-frame state: descriptor pool and command buffer.
    try vk.check(d.vk.vkResetDescriptorPool(d.device, d.desc_pool, 0));
    try vk.check(d.vk.vkResetCommandBuffer(d.frame_cmd, 0));
    const bi = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    try vk.check(d.vk.vkBeginCommandBuffer(d.frame_cmd, &bi));

    return .{
        .renderer = renderer,
        .target = target,
        .cmd = d.frame_cmd,
    };
}

/// Add a render pass to this frame with the provided attachments.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{ .attachments = attachments }, self.cmd);
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
/// (We always block on the render fence — see the file comment — so
/// `sync` changes nothing here.)
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    var health: Health = .healthy;
    self.submit() catch |err| {
        log.err("frame submission failed err={}", .{err});
        health = .unhealthy;
    };

    // Queue presentation before waiting on the CPU. Android's WSI expects the
    // render-finished semaphore to be consumed by presentation as part of the
    // same queue progression as the submission that signals it.
    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("failed to present render target: err={}", .{err});
            health = .unhealthy;
        };

        self.waitAndCleanup() catch |err| {
            log.err("frame completion wait failed err={}", .{err});
            health = .unhealthy;
        };
    }

    // IMPORTANT: frameCompleted must always be called exactly once per
    // begun frame or the generic renderer's swap-chain semaphore leaks
    // and rendering deadlocks.
    self.renderer.frameCompleted(health);
}

fn submit(self: *const Self) vk.Error!void {
    const d = vk.dev();
    try vk.check(d.vk.vkEndCommandBuffer(self.cmd));

    d.mutex.lock();
    defer d.mutex.unlock();

    const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const image_available = self.renderer.api.presentation.image_available;
    const render_finished = self.renderer.api.presentation.render_finished.items[
        self.renderer.api.presentation.active_image
    ];
    const si = std.mem.zeroInit(c.VkSubmitInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &image_available,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &self.cmd,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &render_finished,
    });
    try vk.check(d.vk.vkQueueSubmit(d.queue, 1, &si, d.frame_fence));
}

fn waitAndCleanup(self: *const Self) vk.Error!void {
    _ = self;
    const d = vk.dev();
    try vk.check(d.vk.vkWaitForFences(
        d.device,
        1,
        &d.frame_fence,
        c.VK_TRUE,
        std.math.maxInt(u64),
    ));
    try vk.check(d.vk.vkResetFences(d.device, 1, &d.frame_fence));

    // GPU work is done; transient framebuffers and deferred-destroy
    // buffers (see buffer.zig Raw.deinit) can go.
    for (d.pending_framebuffers.items) |fb| {
        d.vk.vkDestroyFramebuffer(d.device, fb, null);
    }
    d.pending_framebuffers.clearRetainingCapacity();

    for (d.pending_buffers.items) |b| {
        d.vk.vkDestroyBuffer(d.device, b.buf, null);
        d.vk.vkFreeMemory(d.device, b.memory, null);
    }
    d.pending_buffers.clearRetainingCapacity();
}
