//! Wrapper for handling render passes, mirroring `opengl/RenderPass.zig`.
//!
//! The actual vkCmdBeginRenderPass is deferred until the first step so
//! that an empty pass costs nothing. Each step: resolve the VkPipeline
//! for the attachment's format, allocate + write descriptor sets from
//! the per-frame pool (set 0 = UBO/SSBO, set 1 = combined image
//! samplers), bind vertex buffer 0, draw instanced.
//!
//! Y orientation: ghostty's projection matrix is the GL one (top-left
//! origin mapping to NDC +Y). A negative-height viewport flips Vulkan's
//! Y-down NDC so the rendered image has the terminal's top at row 0 —
//! which is exactly what a dmabuf consumer expects.
const Self = @This();

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const bufferpkg = @import("buffer.zig");

const log = std.log.scoped(.vulkan);

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.Raw = null,
    buffers: []const ?bufferpkg.Raw = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: vk.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

attachments: []const Options.Attachment,
cmd: c.VkCommandBuffer,

/// Set once the VkRenderPass instance has begun (first step).
begun: bool = false,
/// Whether recording failed; subsequent steps are skipped.
broken: bool = false,

step_number: usize = 0,

/// The most recent globals UBO seen in a step. GL and Metal keep the
/// globals binding as persistent state across draws, so steps that
/// don't need to *change* it omit `uniforms` (image.zig does this).
/// We allocate a fresh descriptor set per step, so binding 0 must be
/// re-written from this carried value or the shader (image.v.glsl
/// reads projection_matrix/cell_size) samples an unwritten descriptor.
last_uniforms: ?bufferpkg.Raw = null,

/// Cached attachment info resolved at begin.
att_format: vk.AttachmentFormat = .bgra_unorm,
att_width: u32 = 0,
att_height: u32 = 0,

/// Begin a render pass.
pub fn begin(opts: Options, cmd: c.VkCommandBuffer) Self {
    return .{
        .attachments = opts.attachments,
        .cmd = cmd,
    };
}

fn ensureBegun(self: *Self) vk.Error!void {
    if (self.begun) return;
    const d = vk.dev();

    const att = self.attachments[0];
    const view: c.VkImageView, const format: vk.AttachmentFormat, const w: u32, const h: u32 = switch (att.target) {
        .target => |t| .{
            t.view,
            t.attachmentFormat(),
            @intCast(t.width),
            @intCast(t.height),
        },
        .texture => |t| .{
            t.view,
            t.attachmentFormat() orelse return error.VulkanFailed,
            @intCast(t.width),
            @intCast(t.height),
        },
    };

    // All of generic.zig's passes clear; the cached render passes are
    // CLEAR/UNDEFINED-load. (clear_color == null would need a LOAD
    // pass; warn if we ever see it.)
    if (att.clear_color == null) log.warn(
        "render pass without clear_color; contents will be cleared anyway",
        .{},
    );
    const rp = try d.renderPassFor(format, true);

    const fbci = std.mem.zeroInit(c.VkFramebufferCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = rp,
        .attachmentCount = 1,
        .pAttachments = &view,
        .width = w,
        .height = h,
        .layers = 1,
    });
    var fb: c.VkFramebuffer = null;
    try vk.check(d.vk.vkCreateFramebuffer(d.device, &fbci, null, &fb));
    d.mutex.lock();
    d.pending_framebuffers.append(d.alloc, fb) catch {
        d.mutex.unlock();
        d.vk.vkDestroyFramebuffer(d.device, fb, null);
        return error.OutOfMemory;
    };
    d.mutex.unlock();

    const cc = att.clear_color orelse [4]f32{ 0, 0, 0, 0 };
    const clear_value = c.VkClearValue{
        .color = .{ .float32 = cc },
    };
    const rpbi = std.mem.zeroInit(c.VkRenderPassBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = rp,
        .framebuffer = fb,
        .renderArea = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = w, .height = h },
        },
        .clearValueCount = 1,
        .pClearValues = &clear_value,
    });
    d.vk.vkCmdBeginRenderPass(self.cmd, &rpbi, c.VK_SUBPASS_CONTENTS_INLINE);

    // Negative-height viewport for the GL->Vulkan Y flip.
    const viewport = c.VkViewport{
        .x = 0,
        .y = @floatFromInt(h),
        .width = @floatFromInt(w),
        .height = -@as(f32, @floatFromInt(h)),
        .minDepth = 0,
        .maxDepth = 1,
    };
    d.vk.vkCmdSetViewport(self.cmd, 0, 1, &viewport);
    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = w, .height = h },
    };
    d.vk.vkCmdSetScissor(self.cmd, 0, 1, &scissor);

    self.att_format = format;
    self.att_width = w;
    self.att_height = h;
    self.begun = true;
}

/// Add a step to this render pass.
///
/// Matching the GL backend, errors are logged and the step skipped.
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    if (self.broken) return;
    self.stepFallible(s) catch |err| {
        log.warn("render pass step failed err={}", .{err});
        self.broken = self.begun == false;
    };
}

fn stepFallible(self: *Self, s: Step) vk.Error!void {
    const d = vk.dev();
    try self.ensureBegun();

    defer self.step_number += 1;

    const pipeline = try s.pipeline.vkPipeline(self.att_format);
    d.vk.vkCmdBindPipeline(self.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);

    // Descriptor set 0: UBO + optional SSBO.
    var set_layouts = [_]c.VkDescriptorSetLayout{
        d.set_layout_globals,
        d.set_layout_textures,
    };
    var sets: [2]c.VkDescriptorSet = .{ null, null };
    const dsai = std.mem.zeroInit(c.VkDescriptorSetAllocateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = d.desc_pool,
        .descriptorSetCount = 2,
        .pSetLayouts = &set_layouts,
    });
    try vk.check(d.vk.vkAllocateDescriptorSets(d.device, &dsai, &sets));

    var writes: [4]c.VkWriteDescriptorSet = undefined;
    var buffer_infos: [2]c.VkDescriptorBufferInfo = undefined;
    var image_infos: [2]c.VkDescriptorImageInfo = undefined;
    var n_writes: u32 = 0;

    // A step without explicit uniforms inherits the previously bound
    // globals (GL/Metal semantics; see last_uniforms doc comment).
    if (s.uniforms) |u| self.last_uniforms = u;

    if (self.last_uniforms) |ubo| {
        buffer_infos[0] = .{
            .buffer = ubo.buf,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        writes[n_writes] = std.mem.zeroInit(c.VkWriteDescriptorSet, .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets[0],
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pBufferInfo = &buffer_infos[0],
        });
        n_writes += 1;
    }

    // Buffer 0 is the vertex buffer; buffers 1.. are storage buffers
    // (binding index matches the GL convention: bindBase(.storage, i)).
    if (s.buffers.len > 1) {
        if (s.buffers[1]) |ssbo| {
            buffer_infos[1] = .{
                .buffer = ssbo.buf,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };
            writes[n_writes] = std.mem.zeroInit(c.VkWriteDescriptorSet, .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = sets[0],
                .dstBinding = 1,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &buffer_infos[1],
            });
            n_writes += 1;
        }
    }

    // Set 1: combined image samplers. A step-provided sampler
    // overrides the texture's own (GL semantics).
    for (s.textures, 0..) |t_opt, i| {
        if (i >= 2) break;
        const tex = t_opt orelse continue;
        var sampler = tex.sampler;
        if (i < s.samplers.len) if (s.samplers[i]) |smp| {
            sampler = smp.sampler;
        };
        image_infos[i] = .{
            .sampler = sampler,
            .imageView = tex.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[n_writes] = std.mem.zeroInit(c.VkWriteDescriptorSet, .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets[1],
            .dstBinding = @as(u32, @intCast(i)),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_infos[i],
        });
        n_writes += 1;
    }

    if (n_writes > 0) d.vk.vkUpdateDescriptorSets(
        d.device,
        n_writes,
        &writes,
        0,
        null,
    );

    d.vk.vkCmdBindDescriptorSets(
        self.cmd,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        d.pipeline_layout,
        0,
        2,
        &sets,
        0,
        null,
    );

    // Vertex buffer.
    if (s.buffers.len > 0) if (s.buffers[0]) |vbo| {
        const offset: c.VkDeviceSize = 0;
        d.vk.vkCmdBindVertexBuffers(self.cmd, 0, 1, &vbo.buf, &offset);
    };

    d.vk.vkCmdDraw(
        self.cmd,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    if (!self.begun) return;
    const d = vk.dev();
    d.vk.vkCmdEndRenderPass(self.cmd);

    // Restore the layout protocol: textures return to
    // SHADER_READ_ONLY (they'll be sampled by the next pass); targets
    // go to GENERAL for the external (dmabuf) consumer.
    switch (self.attachments[0].target) {
        .texture => |t| Texture.barrier(
            self.cmd,
            t.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        ),
        .target => |t| Texture.barrier(
            self.cmd,
            t.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        ),
    }
}
