//! Sampler abstraction, mirroring `opengl/Sampler.zig`.
const Self = @This();

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const Texture = @import("Texture.zig");

const log = std.log.scoped(.vulkan);

/// Options for initializing a sampler; maps to VkSamplerCreateInfo.
pub const Options = struct {
    min_filter: Texture.Filter,
    mag_filter: Texture.Filter,
    wrap_s: Texture.Wrap,
    wrap_t: Texture.Wrap,
};

/// The underlying VkSampler.
sampler: c.VkSampler,

pub const Error = vk.Error;

pub fn init(opts: Options) Error!Self {
    return .{ .sampler = try Texture.createSampler(
        opts.min_filter,
        opts.mag_filter,
        opts.wrap_s,
        opts.wrap_t,
    ) };
}

pub fn deinit(self: Self) void {
    if (self.sampler == null) return;
    const d = vk.dev();
    d.vk.vkDestroySampler(d.device, self.sampler, null);
}
