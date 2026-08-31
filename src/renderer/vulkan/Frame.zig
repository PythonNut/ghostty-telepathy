//! Wrapper for one of the Android Vulkan backend's two frame slots.
//!
//! Recording and queue submission stay on Ghostty's renderer thread. Fence
//! waiting and transient cleanup happen on a single completion worker, which
//! reports completion through the generic renderer's existing callback. This
//! permits one frame of CPU/GPU overlap while keeping backpressure bounded.
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
pub const Options = struct {
    slot: *vk.FrameSlot,
};

renderer: *Renderer,
target: *Target,
slot: *vk.FrameSlot,
cmd: c.VkCommandBuffer,
encoding_started_ns: u64 = 0,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) vk.Error!Self {
    try opts.slot.begin();
    vk.setRecordingSlot(opts.slot);

    return .{
        .renderer = renderer,
        .target = target,
        .slot = opts.slot,
        .cmd = opts.slot.cmd,
    };
}

/// Abandon a begun frame before surface acquisition or submission.
pub fn cancel(self: *const Self) void {
    vk.clearRecordingSlot(self.slot);
    self.slot.discard();
}

/// Add a render pass to this frame with the provided attachments.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(
        .{ .attachments = attachments },
        self.cmd,
        self.slot,
    );
}

/// Complete this frame and present the target.
///
/// If `sync` is true, wait on this frame here. Normal terminal frames enqueue
/// their bounded completion work and return without a CPU-side fence wait.
pub fn complete(self: *const Self, sync: bool) void {
    vk.clearRecordingSlot(self.slot);

    if (self.encoding_started_ns != 0) {
        const encoding_completed_ns = vk.monotonicNanos();
        if (encoding_completed_ns >= self.encoding_started_ns) {
            self.renderer.api.telemetry.recordEncode(
                encoding_completed_ns - self.encoding_started_ns,
            );
        }
    }

    var health: Health = .healthy;
    const submitted_at_ns = self.submit() catch |err| submitted: {
        log.err("frame submission failed err={}", .{err});
        health = .unhealthy;
        break :submitted 0;
    };
    const submitted = health == .healthy;

    // Queue presentation immediately. Android's WSI expects the
    // render-finished semaphore to be consumed by presentation as part of the
    // same queue progression as the submission that signals it.
    if (submitted) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("failed to present render target: err={}", .{err});
            health = .unhealthy;
        };
    }

    // Route synchronous and failed submissions through the same FIFO so slot
    // release order always matches both the generic and Vulkan rotations.
    var sync_semaphore: std.Thread.Semaphore = .{};
    self.renderer.api.completion.enqueue(.{
        .renderer = self.renderer,
        .slot = self.slot,
        .health = health,
        .submitted = submitted,
        .submitted_at_ns = submitted_at_ns,
        .sync = if (sync) &sync_semaphore else null,
    });
    if (sync) sync_semaphore.wait();
}

fn submit(self: *const Self) vk.Error!u64 {
    const d = vk.dev();
    try vk.check(d.vk.vkEndCommandBuffer(self.cmd));

    const started_ns = if (self.renderer.api.telemetry.enabled()) vk.monotonicNanos() else 0;
    d.mutex.lock();
    defer d.mutex.unlock();

    const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const image_available = self.slot.image_available;
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
    const result = d.vk.vkQueueSubmit(d.queue, 1, &si, self.slot.fence);
    const completed_ns = if (started_ns == 0) 0 else vk.monotonicNanos();
    if (started_ns != 0 and completed_ns >= started_ns) {
        self.renderer.api.telemetry.recordQueueSubmit(completed_ns - started_ns);
    }
    try vk.check(result);
    return completed_ns;
}
