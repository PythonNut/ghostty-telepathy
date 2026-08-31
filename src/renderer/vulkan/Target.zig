//! Logical target populated with an Android swapchain image at frame begin.
//!
//! The generic renderer rotates these values to keep its per-frame buffers
//! separate. The Vulkan images themselves remain owned by Android's
//! swapchain, so target creation and destruction perform no GPU allocation.
const Self = @This();

const vk = @import("vk.zig");
const c = vk.c;

pub const Options = struct {
    width: usize,
    height: usize,
    srgb: bool,
};

image: c.VkImage = null,
view: c.VkImageView = null,
width: usize,
height: usize,
format: vk.AttachmentFormat,

pub fn attachmentFormat(self: *const Self) vk.AttachmentFormat {
    return self.format;
}

pub fn init(opts: Options) vk.Error!Self {
    return .{
        .width = opts.width,
        .height = opts.height,
        .format = if (opts.srgb) .bgra_srgb else .bgra_unorm,
    };
}

pub fn deinit(self: *Self) void {
    self.image = null;
    self.view = null;
}
