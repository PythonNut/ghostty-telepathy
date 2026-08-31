//! GPU buffer abstraction, mirroring `opengl/buffer.zig`.
//!
//! Buffers are host-visible + host-coherent (the V3D is a UMA GPU: all
//! its memory types are device-local AND host-visible) and persistently
//! mapped; `sync` is a memcpy. Growth reallocates at 2x, matching the
//! GL backend's policy. Safe because every frame's GPU work is
//! fence-waited before the buffers are reused (see Frame.complete).
const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;

const log = std.log.scoped(.vulkan);

/// Options for initializing a buffer.
pub const Options = struct {
    /// Intended usage; maps to VkBufferUsageFlags.
    usage: Usage = .vertex,

    pub const Usage = enum {
        vertex,
        uniform,
        storage,

        fn toVk(self: Usage) c.VkBufferUsageFlags {
            return switch (self) {
                .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                .storage => c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            };
        }
    };
};

pub const Error = vk.Error;

/// The raw handle passed around by generic.zig via `.buffer`. Shared
/// across all Buffer(T) instantiations.
pub const Raw = struct {
    buf: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    /// Persistently mapped pointer.
    map: ?[*]u8 = null,
    /// Allocated size in bytes.
    size: usize = 0,

    pub fn init(usage: Options.Usage, size_bytes: usize) Error!Raw {
        const d = vk.dev();
        const size = @max(size_bytes, 16);

        const bci = std.mem.zeroInit(c.VkBufferCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage.toVk(),
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        });
        var buf: c.VkBuffer = null;
        try vk.check(d.vk.vkCreateBuffer(d.device, &bci, null, &buf));
        errdefer d.vk.vkDestroyBuffer(d.device, buf, null);

        var reqs: c.VkMemoryRequirements = undefined;
        d.vk.vkGetBufferMemoryRequirements(d.device, buf, &reqs);

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
        errdefer d.vk.vkFreeMemory(d.device, memory, null);

        try vk.check(d.vk.vkBindBufferMemory(d.device, buf, memory, 0));

        var map: ?*anyopaque = null;
        try vk.check(d.vk.vkMapMemory(d.device, memory, 0, c.VK_WHOLE_SIZE, 0, &map));

        return .{
            .buf = buf,
            .memory = memory,
            .map = @ptrCast(map),
            .size = size,
        };
    }

    /// Deinit does NOT destroy the buffer immediately: the handle may
    /// have been recorded into the frame command buffer that hasn't
    /// been submitted yet (image.zig deinitializes its transient
    /// per-placement vertex buffers right after pass.step records
    /// them; submission happens later in Frame.complete). Instead the
    /// buffer is queued on the device and destroyed after the frame
    /// fence signals (Frame.submitAndWait), or at device teardown.
    pub fn deinit(self: Raw) void {
        if (self.buf == null) return;
        const d = vk.dev();
        d.mutex.lock();
        defer d.mutex.unlock();
        d.pending_buffers.append(d.alloc, .{
            .buf = self.buf,
            .memory = self.memory,
        }) catch {
            // Allocation failure tracking the buffer. Destroying it
            // now would be unsafe (it may be recorded in the pending
            // frame command buffer, which a queue drain can't cover),
            // so leak it — strictly better than a GPU use-after-free.
            log.warn("leaking VkBuffer: failed to queue deferred destroy", .{});
        };
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying VkBuffer + mapping; passed by generic.zig
        /// into `RenderPass.Step.uniforms` / `.buffers`.
        buffer: Raw,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length in number of `T`s (not bytes).
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) Error!Self {
            return .{
                .buffer = try Raw.init(opts.usage, len * @sizeOf(T)),
                .opts = opts,
                .len = @max(len, 1),
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) Error!Self {
            var self: Self = try init(opts, data.len);
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: Self) void {
            self.buffer.deinit();
        }

        fn ensureCapacity(self: *Self, count: usize) Error!void {
            if (count * @sizeOf(T) <= self.buffer.size) return;
            const new_len = @max(count * 2, 1);
            const new_raw = try Raw.init(self.opts.usage, new_len * @sizeOf(T));
            self.buffer.deinit();
            self.buffer = new_raw;
            self.len = new_len;
        }

        /// Sync new contents to the buffer, growing it if needed.
        pub fn sync(self: *Self, data: []const T) Error!void {
            try self.ensureCapacity(data.len);
            const bytes = std.mem.sliceAsBytes(data);
            if (bytes.len == 0) return;
            @memcpy(self.buffer.map.?[0..bytes.len], bytes);
        }

        /// Like sync but takes data from an array of ArrayLists.
        /// Returns the number of items synced.
        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) Error!usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;
            try self.ensureCapacity(total_len);
            var offset: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                if (bytes.len == 0) continue;
                @memcpy(
                    self.buffer.map.?[offset..][0..bytes.len],
                    bytes,
                );
                offset += bytes.len;
            }
            return total_len;
        }
    };
}
