//! GPU texture abstraction, mirroring `opengl/Texture.zig`.
//!
//! Textures are optimal-tiled VkImages with a combined-image-sampler
//! view. Uploads go through a transient staging buffer and an
//! immediate (fence-waited) submit — simple and correct; the cost is
//! measured and documented rather than optimized away (atlas updates
//! are bursty but small).
//!
//! Layout protocol: a texture's steady-state layout is always
//! SHADER_READ_ONLY_OPTIMAL. Uploads transition to TRANSFER_DST and
//! back. When a texture is used as a render pass attachment (custom
//! shader ping-pong textures), the render pass discards (clears) it,
//! renders, and the pass wrapper transitions it back to
//! SHADER_READ_ONLY afterwards. This keeps layout state out of the
//! struct entirely, which matters because generic.zig copies these
//! structs by value.
const Self = @This();

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const log = std.log.scoped(.vulkan);

/// Pixel data format; maps to VkFormat together with `srgb`.
pub const Format = enum {
    /// 1 byte per pixel grayscale (VK_FORMAT_R8_UNORM).
    gray,
    /// 4 bytes per pixel RGBA (VK_FORMAT_R8G8B8A8_UNORM / _SRGB).
    rgba,
    /// 4 bytes per pixel BGRA (VK_FORMAT_B8G8R8A8_UNORM / _SRGB).
    bgra,

    pub fn bytesPerPixel(self: Format) usize {
        return switch (self) {
            .gray => 1,
            .rgba, .bgra => 4,
        };
    }

    pub fn toVk(self: Format, srgb: bool) c.VkFormat {
        return switch (self) {
            .gray => c.VK_FORMAT_R8_UNORM,
            .rgba => if (srgb) c.VK_FORMAT_R8G8B8A8_SRGB else c.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb) c.VK_FORMAT_B8G8R8A8_SRGB else c.VK_FORMAT_B8G8R8A8_UNORM,
        };
    }
};

pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp_to_edge, repeat };

/// Options for initializing a texture.
pub const Options = struct {
    format: Format,
    /// Use an sRGB VkFormat variant (shader reads linearize).
    srgb: bool,
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,
};

pub const Error = vk.Error;

image: c.VkImage,
memory: c.VkDeviceMemory,
view: c.VkImageView,
/// Sampler owned by the texture (GL semantics: texture parameters act
/// as the default sampler when a step doesn't provide one).
sampler: c.VkSampler,

/// The width/height of this texture.
width: usize,
height: usize,

/// Format for this texture.
format: Format,
srgb: bool,

/// The vulkan attachment format when this texture is render target
/// capable (rgba/bgra only; gray is never an attachment).
pub fn attachmentFormat(self: Self) ?vk.AttachmentFormat {
    return switch (self.format) {
        .gray => null,
        .rgba => if (self.srgb) .rgba_srgb else .rgba_unorm,
        // bgra textures are never used as pass attachments today, but
        // map them anyway for completeness.
        .bgra => if (self.srgb) .bgra_srgb else .bgra_unorm,
    };
}

/// Initialize a texture, optionally uploading initial data.
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const d = vk.dev();
    const vkfmt = opts.format.toVk(opts.srgb);

    var usage: c.VkImageUsageFlags =
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    // Custom-shader ping-pong textures are render targets.
    if (opts.format != .gray) usage |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    const ici = std.mem.zeroInit(c.VkImageCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = vkfmt,
        .extent = c.VkExtent3D{
            .width = @intCast(@max(width, 1)),
            .height = @intCast(@max(height, 1)),
            .depth = 1,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    });
    var image: c.VkImage = null;
    try vk.check(d.vk.vkCreateImage(d.device, &ici, null, &image));
    errdefer d.vk.vkDestroyImage(d.device, image, null);

    var reqs: c.VkMemoryRequirements = undefined;
    d.vk.vkGetImageMemoryRequirements(d.device, image, &reqs);
    const mem_type = d.findMemoryType(
        reqs.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse d.findMemoryType(reqs.memoryTypeBits, 0) orelse
        return error.VulkanFailed;
    const mai = std.mem.zeroInit(c.VkMemoryAllocateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = reqs.size,
        .memoryTypeIndex = mem_type,
    });
    var memory: c.VkDeviceMemory = null;
    try vk.check(d.vk.vkAllocateMemory(d.device, &mai, null, &memory));
    errdefer d.vk.vkFreeMemory(d.device, memory, null);
    try vk.check(d.vk.vkBindImageMemory(d.device, image, memory, 0));

    const vci = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = vkfmt,
        .subresourceRange = c.VkImageSubresourceRange{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });
    var view: c.VkImageView = null;
    try vk.check(d.vk.vkCreateImageView(d.device, &vci, null, &view));
    errdefer d.vk.vkDestroyImageView(d.device, view, null);

    const sampler = try createSampler(
        opts.min_filter,
        opts.mag_filter,
        opts.wrap_s,
        opts.wrap_t,
    );
    errdefer d.vk.vkDestroySampler(d.device, sampler, null);

    var self: Self = .{
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
        .format = opts.format,
        .srgb = opts.srgb,
    };

    // Establish the steady-state layout (SHADER_READ_ONLY_OPTIMAL),
    // uploading initial data along the way if provided.
    if (data) |dta| {
        try self.replaceRegionInternal(0, 0, width, height, dta, true);
    } else {
        const cmd = try d.immediateBegin();
        barrier(
            cmd,
            image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        );
        try d.immediateSubmit();
    }

    return self;
}

pub fn deinit(self: Self) void {
    if (self.image == null) return;
    const d = vk.dev();
    d.vk.vkDestroySampler(d.device, self.sampler, null);
    d.vk.vkDestroyImageView(d.device, self.view, null);
    d.vk.vkDestroyImage(d.device, self.image, null);
    d.vk.vkFreeMemory(d.device, self.memory, null);
}

pub fn createSampler(
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,
) Error!c.VkSampler {
    const d = vk.dev();
    const sci = std.mem.zeroInit(c.VkSamplerCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = filterToVk(mag_filter),
        .minFilter = filterToVk(min_filter),
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = wrapToVk(wrap_s),
        .addressModeV = wrapToVk(wrap_t),
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    });
    var sampler: c.VkSampler = null;
    try vk.check(d.vk.vkCreateSampler(d.device, &sci, null, &sampler));
    return sampler;
}

fn filterToVk(f: Filter) c.VkFilter {
    return switch (f) {
        .nearest => c.VK_FILTER_NEAREST,
        .linear => c.VK_FILTER_LINEAR,
    };
}

fn wrapToVk(w: Wrap) c.VkSamplerAddressMode {
    return switch (w) {
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
    };
}

/// Record an image layout transition covering all color subresources.
pub fn barrier(
    cmd: c.VkCommandBuffer,
    image: c.VkImage,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
) void {
    const d = vk.dev();
    const imb = std.mem.zeroInit(c.VkImageMemoryBarrier, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_MEMORY_READ_BIT | c.VK_ACCESS_MEMORY_WRITE_BIT,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = c.VkImageSubresourceRange{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });
    d.vk.vkCmdPipelineBarrier(
        cmd,
        c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &imb,
    );
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    try self.replaceRegionInternal(x, y, width, height, data, false);
}

fn replaceRegionInternal(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
    from_undefined: bool,
) Error!void {
    if (width == 0 or height == 0) return;
    const d = vk.dev();

    // Staging buffer.
    const size = width * height * self.format.bytesPerPixel();
    const upload = @min(size, data.len);
    const telemetry_enabled = vk.deviceTelemetryEnabled();
    const telemetry_started = if (telemetry_enabled) vk.monotonicNanos() else 0;
    defer if (telemetry_enabled) vk.recordAtlasUpload(
        upload,
        vk.monotonicNanos() - telemetry_started,
    );
    const bci = std.mem.zeroInit(c.VkBufferCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = @max(upload, 4),
        .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    });
    var staging: c.VkBuffer = null;
    try vk.check(d.vk.vkCreateBuffer(d.device, &bci, null, &staging));
    defer d.vk.vkDestroyBuffer(d.device, staging, null);
    var reqs: c.VkMemoryRequirements = undefined;
    d.vk.vkGetBufferMemoryRequirements(d.device, staging, &reqs);
    const mem_type = d.findMemoryType(
        reqs.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    ) orelse return error.VulkanFailed;
    const mai = std.mem.zeroInit(c.VkMemoryAllocateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = reqs.size,
        .memoryTypeIndex = mem_type,
    });
    var memory: c.VkDeviceMemory = null;
    try vk.check(d.vk.vkAllocateMemory(d.device, &mai, null, &memory));
    defer d.vk.vkFreeMemory(d.device, memory, null);
    try vk.check(d.vk.vkBindBufferMemory(d.device, staging, memory, 0));
    var map: ?*anyopaque = null;
    try vk.check(d.vk.vkMapMemory(d.device, memory, 0, c.VK_WHOLE_SIZE, 0, &map));
    const map_bytes: [*]u8 = @ptrCast(map);
    @memcpy(map_bytes[0..upload], data[0..upload]);
    d.vk.vkUnmapMemory(d.device, memory);

    // Copy.
    const cmd = try d.immediateBegin();
    barrier(
        cmd,
        self.image,
        if (from_undefined)
            c.VK_IMAGE_LAYOUT_UNDEFINED
        else
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    );
    const region = std.mem.zeroInit(c.VkBufferImageCopy, .{
        .bufferOffset = 0,
        .bufferRowLength = 0, // tightly packed
        .bufferImageHeight = 0,
        .imageSubresource = c.VkImageSubresourceLayers{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = c.VkOffset3D{
            .x = @intCast(x),
            .y = @intCast(y),
            .z = 0,
        },
        .imageExtent = c.VkExtent3D{
            .width = @intCast(width),
            .height = @intCast(height),
            .depth = 1,
        },
    });
    d.vk.vkCmdCopyBufferToImage(
        cmd,
        staging,
        self.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &region,
    );
    barrier(
        cmd,
        self.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    );
    try d.immediateSubmit();
}
