//! Real Vulkan bindings + shared device context for the Vulkan backend.
//!
//! Bindings: `vulkan/vulkan_core.h` via @cImport with VK_NO_PROTOTYPES;
//! libvulkan.so.1 is dlopen'd at first use (no link-time dependency), and
//! entry points are resolved through vkGetInstanceProcAddr /
//! vkGetDeviceProcAddr into explicit dispatch tables.
//!
//! Device context: a single refcounted global `Device` shared by every
//! surface's renderer (mirroring how all GL contexts share state via GDK).
//! It owns the VkInstance/VkDevice/queue, the shared descriptor set/pipeline
//! layouts, a render pass cache, a pipeline cache, and an "immediate submit"
//! helper used for staging uploads.
//!
//! Threading: ghostty's GTK apprt sets `must_draw_from_app_thread`, so all
//! rendering happens on the GTK main thread. Init/deinit also happen there.
//! A mutex still guards submissions and the caches for safety.
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vulkan);

pub const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("android/native_window.h");
});

/// Draw primitive topology (subset generic.zig uses).
pub const Primitive = enum {
    point,
    line,
    line_strip,
    triangle,
    triangle_strip,

    pub fn toVk(self: Primitive) c.VkPrimitiveTopology {
        return switch (self) {
            .point => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
            .line => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
            .line_strip => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
            .triangle => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .triangle_strip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        };
    }
};

pub const Error = error{
    VulkanUnavailable,
    VulkanFailed,
    OutOfMemory,
};

pub fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) {
        log.warn("vulkan call failed result={d}", .{result});
        return error.VulkanFailed;
    }
}

fn Pfn(comptime name: [:0]const u8) type {
    return std.meta.Child(@field(c, "PFN_" ++ name));
}

/// Entry points resolved with a null instance.
const GlobalDispatch = struct {
    vkCreateInstance: Pfn("vkCreateInstance"),
};

/// Instance-level entry points.
const InstanceDispatch = struct {
    vkDestroyInstance: Pfn("vkDestroyInstance"),
    vkEnumeratePhysicalDevices: Pfn("vkEnumeratePhysicalDevices"),
    vkGetPhysicalDeviceProperties: Pfn("vkGetPhysicalDeviceProperties"),
    vkGetPhysicalDeviceQueueFamilyProperties: Pfn("vkGetPhysicalDeviceQueueFamilyProperties"),
    vkGetPhysicalDeviceMemoryProperties: Pfn("vkGetPhysicalDeviceMemoryProperties"),
    vkGetPhysicalDeviceFormatProperties2: Pfn("vkGetPhysicalDeviceFormatProperties2"),
    vkGetPhysicalDeviceImageFormatProperties2: Pfn("vkGetPhysicalDeviceImageFormatProperties2"),
    vkEnumerateDeviceExtensionProperties: Pfn("vkEnumerateDeviceExtensionProperties"),
    vkGetPhysicalDeviceSurfaceSupportKHR: Pfn("vkGetPhysicalDeviceSurfaceSupportKHR"),
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: Pfn("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"),
    vkGetPhysicalDeviceSurfaceFormatsKHR: Pfn("vkGetPhysicalDeviceSurfaceFormatsKHR"),
    vkGetPhysicalDeviceSurfacePresentModesKHR: Pfn("vkGetPhysicalDeviceSurfacePresentModesKHR"),
    vkCreateAndroidSurfaceKHR: Pfn("vkCreateAndroidSurfaceKHR"),
    vkDestroySurfaceKHR: Pfn("vkDestroySurfaceKHR"),
    vkCreateDevice: Pfn("vkCreateDevice"),
    vkGetDeviceProcAddr: Pfn("vkGetDeviceProcAddr"),
};

/// Device-level entry points.
const DeviceDispatch = struct {
    vkDestroyDevice: Pfn("vkDestroyDevice"),
    vkGetDeviceQueue: Pfn("vkGetDeviceQueue"),
    vkDeviceWaitIdle: Pfn("vkDeviceWaitIdle"),
    vkQueueSubmit: Pfn("vkQueueSubmit"),
    vkQueuePresentKHR: Pfn("vkQueuePresentKHR"),
    vkQueueWaitIdle: Pfn("vkQueueWaitIdle"),

    vkCreateCommandPool: Pfn("vkCreateCommandPool"),
    vkDestroyCommandPool: Pfn("vkDestroyCommandPool"),
    vkAllocateCommandBuffers: Pfn("vkAllocateCommandBuffers"),
    vkFreeCommandBuffers: Pfn("vkFreeCommandBuffers"),
    vkResetCommandBuffer: Pfn("vkResetCommandBuffer"),
    vkBeginCommandBuffer: Pfn("vkBeginCommandBuffer"),
    vkEndCommandBuffer: Pfn("vkEndCommandBuffer"),

    vkCreateFence: Pfn("vkCreateFence"),
    vkDestroyFence: Pfn("vkDestroyFence"),
    vkResetFences: Pfn("vkResetFences"),
    vkWaitForFences: Pfn("vkWaitForFences"),
    vkCreateSemaphore: Pfn("vkCreateSemaphore"),
    vkDestroySemaphore: Pfn("vkDestroySemaphore"),

    vkCreateSwapchainKHR: Pfn("vkCreateSwapchainKHR"),
    vkDestroySwapchainKHR: Pfn("vkDestroySwapchainKHR"),
    vkGetSwapchainImagesKHR: Pfn("vkGetSwapchainImagesKHR"),
    vkAcquireNextImageKHR: Pfn("vkAcquireNextImageKHR"),

    vkCreateBuffer: Pfn("vkCreateBuffer"),
    vkDestroyBuffer: Pfn("vkDestroyBuffer"),
    vkGetBufferMemoryRequirements: Pfn("vkGetBufferMemoryRequirements"),
    vkAllocateMemory: Pfn("vkAllocateMemory"),
    vkFreeMemory: Pfn("vkFreeMemory"),
    vkBindBufferMemory: Pfn("vkBindBufferMemory"),
    vkMapMemory: Pfn("vkMapMemory"),
    vkUnmapMemory: Pfn("vkUnmapMemory"),

    vkCreateImage: Pfn("vkCreateImage"),
    vkDestroyImage: Pfn("vkDestroyImage"),
    vkGetImageMemoryRequirements: Pfn("vkGetImageMemoryRequirements"),
    vkBindImageMemory: Pfn("vkBindImageMemory"),
    vkCreateImageView: Pfn("vkCreateImageView"),
    vkDestroyImageView: Pfn("vkDestroyImageView"),
    vkGetImageSubresourceLayout: Pfn("vkGetImageSubresourceLayout"),

    vkCreateSampler: Pfn("vkCreateSampler"),
    vkDestroySampler: Pfn("vkDestroySampler"),

    vkCreateShaderModule: Pfn("vkCreateShaderModule"),
    vkDestroyShaderModule: Pfn("vkDestroyShaderModule"),

    vkCreateDescriptorSetLayout: Pfn("vkCreateDescriptorSetLayout"),
    vkDestroyDescriptorSetLayout: Pfn("vkDestroyDescriptorSetLayout"),
    vkCreatePipelineLayout: Pfn("vkCreatePipelineLayout"),
    vkDestroyPipelineLayout: Pfn("vkDestroyPipelineLayout"),
    vkCreateDescriptorPool: Pfn("vkCreateDescriptorPool"),
    vkDestroyDescriptorPool: Pfn("vkDestroyDescriptorPool"),
    vkResetDescriptorPool: Pfn("vkResetDescriptorPool"),
    vkAllocateDescriptorSets: Pfn("vkAllocateDescriptorSets"),
    vkUpdateDescriptorSets: Pfn("vkUpdateDescriptorSets"),

    vkCreateGraphicsPipelines: Pfn("vkCreateGraphicsPipelines"),
    vkDestroyPipeline: Pfn("vkDestroyPipeline"),

    vkCreateRenderPass: Pfn("vkCreateRenderPass"),
    vkDestroyRenderPass: Pfn("vkDestroyRenderPass"),
    vkCreateFramebuffer: Pfn("vkCreateFramebuffer"),
    vkDestroyFramebuffer: Pfn("vkDestroyFramebuffer"),

    vkCmdBeginRenderPass: Pfn("vkCmdBeginRenderPass"),
    vkCmdEndRenderPass: Pfn("vkCmdEndRenderPass"),
    vkCmdBindPipeline: Pfn("vkCmdBindPipeline"),
    vkCmdBindDescriptorSets: Pfn("vkCmdBindDescriptorSets"),
    vkCmdBindVertexBuffers: Pfn("vkCmdBindVertexBuffers"),
    vkCmdDraw: Pfn("vkCmdDraw"),
    vkCmdSetViewport: Pfn("vkCmdSetViewport"),
    vkCmdSetScissor: Pfn("vkCmdSetScissor"),
    vkCmdPipelineBarrier: Pfn("vkCmdPipelineBarrier"),
    vkCmdCopyBufferToImage: Pfn("vkCmdCopyBufferToImage"),
};

/// Extension entry points that may legitimately be absent.
const ExtDispatch = struct {
    vkGetImageDrmFormatModifierPropertiesEXT: ?Pfn("vkGetImageDrmFormatModifierPropertiesEXT") = null,
    vkGetMemoryFdKHR: ?Pfn("vkGetMemoryFdKHR") = null,
};

/// The color formats we may render to. Used to key render pass /
/// pipeline caches.
pub const AttachmentFormat = enum(u2) {
    bgra_unorm,
    bgra_srgb,
    rgba_unorm,
    rgba_srgb,

    pub fn toVk(self: AttachmentFormat) c.VkFormat {
        return switch (self) {
            .bgra_unorm => c.VK_FORMAT_B8G8R8A8_UNORM,
            .bgra_srgb => c.VK_FORMAT_B8G8R8A8_SRGB,
            .rgba_unorm => c.VK_FORMAT_R8G8B8A8_UNORM,
            .rgba_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        };
    }
};

/// Vertex attribute description derived at comptime from a Zig extern
/// struct, mirroring the GL backend's `autoAttribute`.
pub const VertexAttr = struct {
    location: u32,
    format: c.VkFormat,
    offset: u32,
};

/// Build the vertex attribute table for a vertex attributes struct.
/// The table lives in static constant memory (container-level const).
pub fn vertexAttrs(comptime T: type) []const VertexAttr {
    const S = struct {
        const attrs = computeVertexAttrs(T);
    };
    return &S.attrs;
}

fn computeVertexAttrs(
    comptime T: type,
) [@typeInfo(T).@"struct".fields.len]VertexAttr {
    const fields = @typeInfo(T).@"struct".fields;
    comptime var attrs: [fields.len]VertexAttr = undefined;
    comptime {
        for (fields, 0..) |field, i| {
            const FT = switch (@typeInfo(field.type)) {
                .@"struct" => |s| s.backing_integer.?,
                .@"enum" => |e| e.tag_type,
                else => field.type,
            };
            const size, const IT = switch (@typeInfo(FT)) {
                .array => |a| .{ a.len, a.child },
                else => .{ 1, FT },
            };
            const format: c.VkFormat = switch (IT) {
                u8 => switch (size) {
                    1 => c.VK_FORMAT_R8_UINT,
                    2 => c.VK_FORMAT_R8G8_UINT,
                    4 => c.VK_FORMAT_R8G8B8A8_UINT,
                    else => @compileError("unsupported attr size"),
                },
                i8 => switch (size) {
                    1 => c.VK_FORMAT_R8_SINT,
                    2 => c.VK_FORMAT_R8G8_SINT,
                    4 => c.VK_FORMAT_R8G8B8A8_SINT,
                    else => @compileError("unsupported attr size"),
                },
                u16 => switch (size) {
                    1 => c.VK_FORMAT_R16_UINT,
                    2 => c.VK_FORMAT_R16G16_UINT,
                    4 => c.VK_FORMAT_R16G16B16A16_UINT,
                    else => @compileError("unsupported attr size"),
                },
                i16 => switch (size) {
                    1 => c.VK_FORMAT_R16_SINT,
                    2 => c.VK_FORMAT_R16G16_SINT,
                    4 => c.VK_FORMAT_R16G16B16A16_SINT,
                    else => @compileError("unsupported attr size"),
                },
                u32 => switch (size) {
                    1 => c.VK_FORMAT_R32_UINT,
                    2 => c.VK_FORMAT_R32G32_UINT,
                    4 => c.VK_FORMAT_R32G32B32A32_UINT,
                    else => @compileError("unsupported attr size"),
                },
                i32 => switch (size) {
                    1 => c.VK_FORMAT_R32_SINT,
                    2 => c.VK_FORMAT_R32G32_SINT,
                    4 => c.VK_FORMAT_R32G32B32A32_SINT,
                    else => @compileError("unsupported attr size"),
                },
                f32 => switch (size) {
                    1 => c.VK_FORMAT_R32_SFLOAT,
                    2 => c.VK_FORMAT_R32G32_SFLOAT,
                    4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
                    else => @compileError("unsupported attr size"),
                },
                else => @compileError("unsupported attr type " ++ @typeName(IT)),
            };
            attrs[i] = .{
                .location = i,
                .format = format,
                .offset = @offsetOf(T, field.name),
            };
        }
    }
    return attrs;
}

pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;
/// DRM fourcc 'AR24' (ARGB8888 packed little-endian == VK B8G8R8A8 bytes).
pub const DRM_FORMAT_ARGB8888: u32 = 0x34325241;
/// DRM fourcc 'XR24'.
pub const DRM_FORMAT_XRGB8888: u32 = 0x34325258;

/// The shared device context.
pub const Device = struct {
    alloc: Allocator,
    lib: std.DynLib,
    gipa: Pfn("vkGetInstanceProcAddr"),
    vkg: GlobalDispatch,
    vki: InstanceDispatch,
    vk: DeviceDispatch,
    ext: ExtDispatch,

    instance: c.VkInstance,
    phys: c.VkPhysicalDevice,
    props: c.VkPhysicalDeviceProperties,
    mem_props: c.VkPhysicalDeviceMemoryProperties,
    device: c.VkDevice,
    queue_family: u32,
    queue: c.VkQueue,

    /// True if VK_EXT_image_drm_format_modifier is enabled (preferred
    /// path for dmabuf-exported targets). If false we fall back to
    /// VK_IMAGE_TILING_LINEAR export, which Mesa accepts in practice.
    has_modifiers: bool,

    /// Command pool + buffer + fence for immediate (staging) submissions.
    imm_pool: c.VkCommandPool,
    imm_cmd: c.VkCommandBuffer,
    imm_fence: c.VkFence,

    /// Command buffer + fence used for frame rendering (one frame's GPU
    /// work is in flight at a time; Frame.complete fence-waits).
    frame_cmd: c.VkCommandBuffer,
    frame_fence: c.VkFence,

    /// Descriptor pool reset at the start of every frame.
    desc_pool: c.VkDescriptorPool,

    /// Framebuffers created during the current frame; destroyed after
    /// the frame's fence wait (framebuffers are transient per pass).
    pending_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .{},

    /// Buffers whose deinit was requested while their last use may
    /// still sit in a recorded-but-unsubmitted (or in-flight) command
    /// buffer — e.g. the transient per-placement vertex buffers that
    /// image.zig deinitializes right after pass.step records them.
    /// Actually destroyed after the frame's fence wait, mirroring
    /// pending_framebuffers.
    pending_buffers: std.ArrayListUnmanaged(PendingBuffer) = .{},

    /// Shared descriptor set layouts and the single pipeline layout
    /// every pipeline uses:
    ///   set 0: binding 0 = UBO, binding 1 = readonly SSBO
    ///   set 1: bindings 0..1 = combined image samplers
    set_layout_globals: c.VkDescriptorSetLayout,
    set_layout_textures: c.VkDescriptorSetLayout,
    pipeline_layout: c.VkPipelineLayout,

    /// Render pass cache: [format][load_is_clear].
    render_passes: [4][2]?c.VkRenderPass = .{ .{ null, null }, .{ null, null }, .{ null, null }, .{ null, null } },

    /// Pipeline cache keyed by shader identity + attachment format.
    pipelines: std.AutoHashMapUnmanaged(PipelineKey, c.VkPipeline) = .{},

    /// Guards queue submissions and the caches.
    mutex: std.Thread.Mutex = .{},

    pub const PendingBuffer = struct {
        buf: c.VkBuffer,
        memory: c.VkDeviceMemory,
    };

    pub const PipelineKey = struct {
        vert: usize, // pointer identity of the embedded SPIR-V
        frag: usize,
        format: AttachmentFormat,
    };

    const required_exts = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

    fn loadDispatch(
        comptime T: type,
        gipa: Pfn("vkGetInstanceProcAddr"),
        instance: c.VkInstance,
    ) Error!T {
        var t: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const p = gipa(instance, field.name.ptr) orelse {
                log.warn("missing vulkan entry point: {s}", .{field.name});
                return error.VulkanUnavailable;
            };
            @field(t, field.name) = @ptrCast(p);
        }
        return t;
    }

    fn loadDeviceDispatch(
        gdpa: Pfn("vkGetDeviceProcAddr"),
        device: c.VkDevice,
    ) Error!DeviceDispatch {
        var t: DeviceDispatch = undefined;
        inline for (@typeInfo(DeviceDispatch).@"struct".fields) |field| {
            const p = gdpa(device, field.name.ptr) orelse {
                log.warn("missing vulkan device entry point: {s}", .{field.name});
                return error.VulkanUnavailable;
            };
            @field(t, field.name) = @ptrCast(p);
        }
        return t;
    }

    pub fn init(alloc: Allocator) Error!*Device {
        var lib = std.DynLib.open("libvulkan.so") catch {
            log.warn("libvulkan.so not found; vulkan renderer unavailable", .{});
            return error.VulkanUnavailable;
        };
        errdefer lib.close();

        const gipa_opt = lib.lookup(
            c.PFN_vkGetInstanceProcAddr,
            "vkGetInstanceProcAddr",
        ) orelse return error.VulkanUnavailable;
        const gipa: Pfn("vkGetInstanceProcAddr") = gipa_opt orelse
            return error.VulkanUnavailable;

        const vkg = try loadDispatch(GlobalDispatch, gipa, null);

        const instance_exts = [_][*:0]const u8{
            c.VK_KHR_SURFACE_EXTENSION_NAME,
            c.VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
        };

        // Telepathy's current prototype floor is Android 15 / Vulkan 1.3.
        const app_info = std.mem.zeroInit(c.VkApplicationInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Telepathy",
            .pEngineName = "Ghostty generic renderer",
            .apiVersion = c.VK_API_VERSION_1_3,
        });
        const ici = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = instance_exts.len,
            .ppEnabledExtensionNames = &instance_exts,
        });
        var instance: c.VkInstance = null;
        try check(vkg.vkCreateInstance(&ici, null, &instance));

        const vki = try loadDispatch(InstanceDispatch, gipa, instance);
        errdefer vki.vkDestroyInstance(instance, null);

        // Select a Vulkan 1.3 graphics queue. The single long-lived Android
        // surface validates presentation support after device creation; a
        // throwaway probe surface would reconnect the same ANativeWindow.
        var count: u32 = 0;
        try check(vki.vkEnumeratePhysicalDevices(instance, &count, null));
        if (count == 0) {
            log.warn("no vulkan physical devices", .{});
            return error.VulkanUnavailable;
        }
        var phys_devs: [8]c.VkPhysicalDevice = undefined;
        count = @min(count, phys_devs.len);
        try check(vki.vkEnumeratePhysicalDevices(instance, &count, &phys_devs));
        var phys: c.VkPhysicalDevice = null;
        var qfi: u32 = 0;
        for (phys_devs[0..count]) |candidate| {
            var candidate_props: c.VkPhysicalDeviceProperties = undefined;
            vki.vkGetPhysicalDeviceProperties(candidate, &candidate_props);
            if (candidate_props.apiVersion < c.VK_API_VERSION_1_3) continue;

            var qf_count: u32 = 0;
            vki.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &qf_count, null);
            var qfs: [16]c.VkQueueFamilyProperties = undefined;
            qf_count = @min(qf_count, qfs.len);
            vki.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &qf_count, &qfs);
            for (qfs[0..qf_count], 0..) |qf, i| {
                if (qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                    phys = candidate;
                    qfi = @intCast(i);
                    break;
                }
            }
            if (phys != null) break;
        }
        if (phys == null) {
            log.warn("no Vulkan 1.3 graphics device", .{});
            return error.VulkanUnavailable;
        }

        var props: c.VkPhysicalDeviceProperties = undefined;
        vki.vkGetPhysicalDeviceProperties(phys, &props);
        log.info("vulkan device: {s} api={d}.{d}.{d}", .{
            std.mem.sliceTo(&props.deviceName, 0),
            c.VK_API_VERSION_MAJOR(props.apiVersion),
            c.VK_API_VERSION_MINOR(props.apiVersion),
            c.VK_API_VERSION_PATCH(props.apiVersion),
        });

        var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
        vki.vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);

        // Check extensions.
        var ext_count: u32 = 0;
        try check(vki.vkEnumerateDeviceExtensionProperties(phys, null, &ext_count, null));
        const exts = alloc.alloc(c.VkExtensionProperties, ext_count) catch
            return error.OutOfMemory;
        defer alloc.free(exts);
        try check(vki.vkEnumerateDeviceExtensionProperties(phys, null, &ext_count, exts.ptr));
        var missing_required = false;
        for (required_exts) |want| {
            var found = false;
            for (exts) |e| {
                if (std.mem.eql(
                    u8,
                    std.mem.sliceTo(&e.extensionName, 0),
                    std.mem.span(want),
                )) found = true;
            }
            if (!found) {
                log.warn("required vulkan extension missing: {s}", .{want});
                missing_required = true;
            }
        }
        if (missing_required) return error.VulkanUnavailable;

        // Device.
        const prio: f32 = 1.0;
        const qci = std.mem.zeroInit(c.VkDeviceQueueCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = qfi,
            .queueCount = 1,
            .pQueuePriorities = &prio,
        });
        const dci = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &qci,
            .enabledExtensionCount = required_exts.len,
            .ppEnabledExtensionNames = &required_exts,
        });
        var device: c.VkDevice = null;
        try check(vki.vkCreateDevice(phys, &dci, null, &device));

        const vk = try loadDeviceDispatch(vki.vkGetDeviceProcAddr, device);
        errdefer vk.vkDestroyDevice(device, null);

        var queue: c.VkQueue = null;
        vk.vkGetDeviceQueue(device, qfi, 0, &queue);

        // Immediate-submit machinery.
        const cpci = std.mem.zeroInit(c.VkCommandPoolCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = qfi,
        });
        var imm_pool: c.VkCommandPool = null;
        try check(vk.vkCreateCommandPool(device, &cpci, null, &imm_pool));
        errdefer vk.vkDestroyCommandPool(device, imm_pool, null);

        const cbai = std.mem.zeroInit(c.VkCommandBufferAllocateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = imm_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });
        var imm_cmd: c.VkCommandBuffer = null;
        try check(vk.vkAllocateCommandBuffers(device, &cbai, &imm_cmd));

        const fci = std.mem.zeroInit(c.VkFenceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        });
        var imm_fence: c.VkFence = null;
        try check(vk.vkCreateFence(device, &fci, null, &imm_fence));
        errdefer vk.vkDestroyFence(device, imm_fence, null);

        var frame_cmd: c.VkCommandBuffer = null;
        try check(vk.vkAllocateCommandBuffers(device, &cbai, &frame_cmd));
        var frame_fence: c.VkFence = null;
        try check(vk.vkCreateFence(device, &fci, null, &frame_fence));
        errdefer vk.vkDestroyFence(device, frame_fence, null);

        // Descriptor pool, reset per frame.
        const pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 256 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 256 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 512 },
        };
        const dpci = std.mem.zeroInit(c.VkDescriptorPoolCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 512,
            .poolSizeCount = @as(u32, pool_sizes.len),
            .pPoolSizes = &pool_sizes,
        });
        var desc_pool: c.VkDescriptorPool = null;
        try check(vk.vkCreateDescriptorPool(device, &dpci, null, &desc_pool));
        errdefer vk.vkDestroyDescriptorPool(device, desc_pool, null);

        // Descriptor set layouts.
        const globals_bindings = [_]c.VkDescriptorSetLayoutBinding{
            std.mem.zeroInit(c.VkDescriptorSetLayoutBinding, .{
                .binding = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            }),
            std.mem.zeroInit(c.VkDescriptorSetLayoutBinding, .{
                .binding = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            }),
        };
        const gdsl = std.mem.zeroInit(c.VkDescriptorSetLayoutCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @as(u32, globals_bindings.len),
            .pBindings = &globals_bindings,
        });
        var set_layout_globals: c.VkDescriptorSetLayout = null;
        try check(vk.vkCreateDescriptorSetLayout(device, &gdsl, null, &set_layout_globals));
        errdefer vk.vkDestroyDescriptorSetLayout(device, set_layout_globals, null);

        const tex_bindings = [_]c.VkDescriptorSetLayoutBinding{
            std.mem.zeroInit(c.VkDescriptorSetLayoutBinding, .{
                .binding = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            }),
            std.mem.zeroInit(c.VkDescriptorSetLayoutBinding, .{
                .binding = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            }),
        };
        const tdsl = std.mem.zeroInit(c.VkDescriptorSetLayoutCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @as(u32, tex_bindings.len),
            .pBindings = &tex_bindings,
        });
        var set_layout_textures: c.VkDescriptorSetLayout = null;
        try check(vk.vkCreateDescriptorSetLayout(device, &tdsl, null, &set_layout_textures));
        errdefer vk.vkDestroyDescriptorSetLayout(device, set_layout_textures, null);

        const set_layouts = [_]c.VkDescriptorSetLayout{
            set_layout_globals,
            set_layout_textures,
        };
        const plci = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = @as(u32, set_layouts.len),
            .pSetLayouts = &set_layouts,
        });
        var pipeline_layout: c.VkPipelineLayout = null;
        try check(vk.vkCreatePipelineLayout(device, &plci, null, &pipeline_layout));
        errdefer vk.vkDestroyPipelineLayout(device, pipeline_layout, null);

        const self = alloc.create(Device) catch return error.OutOfMemory;
        self.* = .{
            .alloc = alloc,
            .lib = lib,
            .gipa = gipa,
            .vkg = vkg,
            .vki = vki,
            .vk = vk,
            .ext = .{},
            .instance = instance,
            .phys = phys,
            .props = props,
            .mem_props = mem_props,
            .device = device,
            .queue_family = qfi,
            .queue = queue,
            .has_modifiers = false,
            .imm_pool = imm_pool,
            .imm_cmd = imm_cmd,
            .imm_fence = imm_fence,
            .frame_cmd = frame_cmd,
            .frame_fence = frame_fence,
            .desc_pool = desc_pool,
            .set_layout_globals = set_layout_globals,
            .set_layout_textures = set_layout_textures,
            .pipeline_layout = pipeline_layout,
        };
        return self;
    }

    pub fn deinit(self: *Device) void {
        const vk = &self.vk;
        _ = vk.vkDeviceWaitIdle(self.device);

        var it = self.pipelines.valueIterator();
        while (it.next()) |p| vk.vkDestroyPipeline(self.device, p.*, null);
        self.pipelines.deinit(self.alloc);

        for (self.render_passes) |row| for (row) |rp_opt| {
            if (rp_opt) |rp| vk.vkDestroyRenderPass(self.device, rp, null);
        };

        for (self.pending_framebuffers.items) |fb| {
            vk.vkDestroyFramebuffer(self.device, fb, null);
        }
        self.pending_framebuffers.deinit(self.alloc);

        for (self.pending_buffers.items) |b| {
            vk.vkDestroyBuffer(self.device, b.buf, null);
            vk.vkFreeMemory(self.device, b.memory, null);
        }
        self.pending_buffers.deinit(self.alloc);

        vk.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.set_layout_textures, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.set_layout_globals, null);
        vk.vkDestroyDescriptorPool(self.device, self.desc_pool, null);
        vk.vkDestroyFence(self.device, self.frame_fence, null);
        vk.vkDestroyFence(self.device, self.imm_fence, null);
        vk.vkDestroyCommandPool(self.device, self.imm_pool, null);
        vk.vkDestroyDevice(self.device, null);
        self.vki.vkDestroyInstance(self.instance, null);
        self.lib.close();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    /// Find a memory type index with the given required property flags
    /// covering `type_bits`.
    pub fn findMemoryType(
        self: *const Device,
        type_bits: u32,
        flags: c.VkMemoryPropertyFlags,
    ) ?u32 {
        var i: u32 = 0;
        while (i < self.mem_props.memoryTypeCount) : (i += 1) {
            if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (self.mem_props.memoryTypes[i].propertyFlags & flags == flags) return i;
        }
        return null;
    }

    /// Begin the immediate command buffer. Caller must call
    /// `immediateSubmit` after recording. The device mutex is held
    /// between the two calls.
    pub fn immediateBegin(self: *Device) Error!c.VkCommandBuffer {
        self.mutex.lock();
        errdefer self.mutex.unlock();
        try check(self.vk.vkResetCommandBuffer(self.imm_cmd, 0));
        const bi = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        try check(self.vk.vkBeginCommandBuffer(self.imm_cmd, &bi));
        return self.imm_cmd;
    }

    /// Submit the immediate command buffer and wait for completion.
    pub fn immediateSubmit(self: *Device) Error!void {
        defer self.mutex.unlock();
        try check(self.vk.vkEndCommandBuffer(self.imm_cmd));
        const si = std.mem.zeroInit(c.VkSubmitInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.imm_cmd,
        });
        try check(self.vk.vkQueueSubmit(self.queue, 1, &si, self.imm_fence));
        try check(self.vk.vkWaitForFences(
            self.device,
            1,
            &self.imm_fence,
            c.VK_TRUE,
            std.math.maxInt(u64),
        ));
        try check(self.vk.vkResetFences(self.device, 1, &self.imm_fence));
    }

    /// Get (or create) the render pass for an attachment format and
    /// load op. Passes are cached forever (there are at most 8).
    pub fn renderPassFor(
        self: *Device,
        format: AttachmentFormat,
        clear: bool,
    ) Error!c.VkRenderPass {
        self.mutex.lock();
        defer self.mutex.unlock();
        const fi: usize = @intFromEnum(format);
        const ci: usize = @intFromBool(clear);
        if (self.render_passes[fi][ci]) |rp| return rp;

        const attachment = std.mem.zeroInit(c.VkAttachmentDescription, .{
            .format = format.toVk(),
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = if (clear)
                @as(c_uint, @intCast(c.VK_ATTACHMENT_LOAD_OP_CLEAR))
            else
                @as(c_uint, @intCast(c.VK_ATTACHMENT_LOAD_OP_LOAD)),
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = if (clear)
                @as(c_uint, @intCast(c.VK_IMAGE_LAYOUT_UNDEFINED))
            else
                @as(c_uint, @intCast(c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)),
            .finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });
        const color_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
        });
        const rpci = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
        });
        var rp: c.VkRenderPass = null;
        try check(self.vk.vkCreateRenderPass(self.device, &rpci, null, &rp));
        self.render_passes[fi][ci] = rp;
        return rp;
    }
};

/// Android presentation state. Ghostty's generic renderer rotates logical
/// frame resources; Android's compositor owns the actual presentable images.
/// A Target is therefore populated with the image acquired here at frame
/// begin, avoiding an offscreen image and copy on the terminal hot path.
pub const Surface = struct {
    alloc: Allocator,
    device: *Device,
    surface: c.VkSurfaceKHR = null,
    swapchain: c.VkSwapchainKHR = null,
    images: std.ArrayListUnmanaged(c.VkImage) = .{},
    views: std.ArrayListUnmanaged(c.VkImageView) = .{},
    render_finished: std.ArrayListUnmanaged(c.VkSemaphore) = .{},
    image_available: c.VkSemaphore = null,
    format: AttachmentFormat = .bgra_srgb,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    requested_width: u32,
    requested_height: u32,
    active_image: u32 = 0,
    needs_recreate: bool = false,

    pub fn init(
        alloc: Allocator,
        device: *Device,
        window: *c.ANativeWindow,
        width: u32,
        height: u32,
    ) Error!Surface {
        const surface_info = std.mem.zeroInit(c.VkAndroidSurfaceCreateInfoKHR, .{
            .sType = c.VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR,
            .window = window,
        });
        var handle: c.VkSurfaceKHR = null;
        try check(device.vki.vkCreateAndroidSurfaceKHR(
            device.instance,
            &surface_info,
            null,
            &handle,
        ));
        errdefer device.vki.vkDestroySurfaceKHR(device.instance, handle, null);

        var present_supported: c.VkBool32 = c.VK_FALSE;
        try check(device.vki.vkGetPhysicalDeviceSurfaceSupportKHR(
            device.phys,
            device.queue_family,
            handle,
            &present_supported,
        ));
        if (present_supported != c.VK_TRUE) return error.VulkanUnavailable;

        const semaphore_info = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        });
        var image_available: c.VkSemaphore = null;
        try check(device.vk.vkCreateSemaphore(
            device.device,
            &semaphore_info,
            null,
            &image_available,
        ));
        errdefer device.vk.vkDestroySemaphore(device.device, image_available, null);

        var result: Surface = .{
            .alloc = alloc,
            .device = device,
            .surface = handle,
            .image_available = image_available,
            .requested_width = width,
            .requested_height = height,
        };
        try result.recreate();
        return result;
    }

    pub fn deinit(self: *Surface) void {
        _ = self.device.vk.vkDeviceWaitIdle(self.device.device);
        self.destroySwapchain();
        if (self.image_available != null) self.device.vk.vkDestroySemaphore(
            self.device.device,
            self.image_available,
            null,
        );
        if (self.surface != null) self.device.vki.vkDestroySurfaceKHR(
            self.device.instance,
            self.surface,
            null,
        );
        self.* = undefined;
    }

    pub fn resize(self: *Surface, width: u32, height: u32) void {
        if (self.requested_width == width and self.requested_height == height) return;
        self.requested_width = width;
        self.requested_height = height;
        self.needs_recreate = true;
    }

    fn destroySwapchain(self: *Surface) void {
        for (self.render_finished.items) |semaphore| {
            self.device.vk.vkDestroySemaphore(self.device.device, semaphore, null);
        }
        for (self.views.items) |view| {
            self.device.vk.vkDestroyImageView(self.device.device, view, null);
        }
        self.views.deinit(self.alloc);
        self.images.deinit(self.alloc);
        self.render_finished.deinit(self.alloc);
        self.views = .{};
        self.images = .{};
        self.render_finished = .{};
        if (self.swapchain != null) self.device.vk.vkDestroySwapchainKHR(
            self.device.device,
            self.swapchain,
            null,
        );
        self.swapchain = null;
    }

    fn recreate(self: *Surface) Error!void {
        if (self.requested_width == 0 or self.requested_height == 0)
            return error.VulkanFailed;

        _ = self.device.vk.vkDeviceWaitIdle(self.device.device);

        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(self.device.vki.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            self.device.phys,
            self.surface,
            &capabilities,
        ));

        var format_count: u32 = 0;
        try check(self.device.vki.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.device.phys,
            self.surface,
            &format_count,
            null,
        ));
        if (format_count == 0) return error.VulkanUnavailable;
        const formats = self.alloc.alloc(c.VkSurfaceFormatKHR, format_count) catch
            return error.OutOfMemory;
        defer self.alloc.free(formats);
        try check(self.device.vki.vkGetPhysicalDeviceSurfaceFormatsKHR(
            self.device.phys,
            self.surface,
            &format_count,
            formats.ptr,
        ));

        const preference = [_]struct { vk: c.VkFormat, generic: AttachmentFormat }{
            .{ .vk = c.VK_FORMAT_B8G8R8A8_SRGB, .generic = .bgra_srgb },
            .{ .vk = c.VK_FORMAT_R8G8B8A8_SRGB, .generic = .rgba_srgb },
            .{ .vk = c.VK_FORMAT_B8G8R8A8_UNORM, .generic = .bgra_unorm },
            .{ .vk = c.VK_FORMAT_R8G8B8A8_UNORM, .generic = .rgba_unorm },
        };
        var chosen: ?c.VkSurfaceFormatKHR = null;
        var attachment_format: AttachmentFormat = .bgra_srgb;
        outer: for (preference) |wanted| {
            for (formats) |candidate| {
                if (candidate.format == wanted.vk and
                    candidate.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
                {
                    chosen = candidate;
                    attachment_format = wanted.generic;
                    break :outer;
                }
            }
        }
        const surface_format = chosen orelse return error.VulkanUnavailable;

        var extent = capabilities.currentExtent;
        if (extent.width == std.math.maxInt(u32)) {
            extent.width = std.math.clamp(
                self.requested_width,
                capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width,
            );
            extent.height = std.math.clamp(
                self.requested_height,
                capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height,
            );
        }
        if (extent.width == 0 or extent.height == 0) return error.VulkanFailed;

        var image_count = @max(@as(u32, 2), capabilities.minImageCount);
        if (capabilities.maxImageCount > 0)
            image_count = @min(image_count, capabilities.maxImageCount);

        const create_info = std.mem.zeroInit(c.VkSwapchainCreateInfoKHR, .{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = selectCompositeAlpha(capabilities.supportedCompositeAlpha),
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = self.swapchain,
        });
        var new_swapchain: c.VkSwapchainKHR = null;
        try check(self.device.vk.vkCreateSwapchainKHR(
            self.device.device,
            &create_info,
            null,
            &new_swapchain,
        ));
        errdefer self.device.vk.vkDestroySwapchainKHR(
            self.device.device,
            new_swapchain,
            null,
        );

        var actual_count: u32 = 0;
        try check(self.device.vk.vkGetSwapchainImagesKHR(
            self.device.device,
            new_swapchain,
            &actual_count,
            null,
        ));
        if (actual_count == 0) return error.VulkanFailed;

        var new_images: std.ArrayListUnmanaged(c.VkImage) = .{};
        errdefer new_images.deinit(self.alloc);
        new_images.resize(self.alloc, actual_count) catch return error.OutOfMemory;
        try check(self.device.vk.vkGetSwapchainImagesKHR(
            self.device.device,
            new_swapchain,
            &actual_count,
            new_images.items.ptr,
        ));

        var new_views: std.ArrayListUnmanaged(c.VkImageView) = .{};
        errdefer {
            for (new_views.items) |view| self.device.vk.vkDestroyImageView(
                self.device.device,
                view,
                null,
            );
            new_views.deinit(self.alloc);
        }
        new_views.ensureTotalCapacity(self.alloc, actual_count) catch
            return error.OutOfMemory;
        var new_render_finished: std.ArrayListUnmanaged(c.VkSemaphore) = .{};
        errdefer {
            for (new_render_finished.items) |semaphore| self.device.vk.vkDestroySemaphore(
                self.device.device,
                semaphore,
                null,
            );
            new_render_finished.deinit(self.alloc);
        }
        new_render_finished.ensureTotalCapacity(self.alloc, actual_count) catch
            return error.OutOfMemory;
        const semaphore_info = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        });
        for (new_images.items) |image| {
            const view_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
                .subresourceRange = c.VkImageSubresourceRange{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            });
            var view: c.VkImageView = null;
            try check(self.device.vk.vkCreateImageView(
                self.device.device,
                &view_info,
                null,
                &view,
            ));
            new_views.appendAssumeCapacity(view);

            var render_finished: c.VkSemaphore = null;
            try check(self.device.vk.vkCreateSemaphore(
                self.device.device,
                &semaphore_info,
                null,
                &render_finished,
            ));
            new_render_finished.appendAssumeCapacity(render_finished);
        }

        self.destroySwapchain();
        self.swapchain = new_swapchain;
        self.images = new_images;
        self.views = new_views;
        self.render_finished = new_render_finished;
        self.format = attachment_format;
        self.extent = extent;
        self.needs_recreate = false;
    }

    pub fn acquire(self: *Surface, target: anytype) Error!void {
        var attempts: u8 = 0;
        while (attempts < 4) : (attempts += 1) {
            if (self.needs_recreate) try self.recreate();
            var image_index: u32 = 0;
            const result = self.device.vk.vkAcquireNextImageKHR(
                self.device.device,
                self.swapchain,
                std.math.maxInt(u64),
                self.image_available,
                null,
                &image_index,
            );
            if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
                log.info("Android swapchain is out of date; recreating", .{});
                self.needs_recreate = true;
                continue;
            }
            if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
                log.err(
                    "Android swapchain image acquisition failed result={d}",
                    .{result},
                );
                return error.VulkanFailed;
            }
            if (result == c.VK_SUBOPTIMAL_KHR)
                log.debug("using suboptimal Android swapchain image", .{});
            // Android can report SUBOPTIMAL for a surface that remains fully
            // usable. Explicit size callbacks are the authoritative rebuild
            // signal; eagerly recreating here can loop during composition.
            self.needs_recreate = false;
            self.active_image = image_index;
            target.image = self.images.items[image_index];
            target.view = self.views.items[image_index];
            target.width = self.extent.width;
            target.height = self.extent.height;
            target.format = self.format;
            return;
        }
        return error.VulkanFailed;
    }

    pub fn present(self: *Surface) Error!void {
        const render_finished = self.render_finished.items[self.active_image];
        const info = std.mem.zeroInit(c.VkPresentInfoKHR, .{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_finished,
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &self.active_image,
        });
        const result = self.device.vk.vkQueuePresentKHR(self.device.queue, &info);
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            self.needs_recreate = true;
            return;
        }
        if (result == c.VK_SUBOPTIMAL_KHR) {
            log.debug("presented a suboptimal Android swapchain image", .{});
            return;
        }
        try check(result);
    }

    fn selectCompositeAlpha(
        supported: c.VkCompositeAlphaFlagsKHR,
    ) c.VkCompositeAlphaFlagBitsKHR {
        const choices = [_]c.VkCompositeAlphaFlagBitsKHR{
            c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
            c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
            c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        };
        for (choices) |choice| if (supported & choice != 0) return choice;
        return c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    }
};

/// Global refcounted device.
var global_device: ?*Device = null;
var global_refs: usize = 0;
var global_mutex: std.Thread.Mutex = .{};

pub fn deviceRef(alloc: Allocator) Error!*Device {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_device == null) {
        global_device = try Device.init(alloc);
    }
    global_refs += 1;
    return global_device.?;
}

pub fn deviceUnref() void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_refs -= 1;
    if (global_refs == 0) {
        if (global_device) |d| d.deinit();
        global_device = null;
    }
}

/// Get the global device, asserting it exists. Resource types
/// (Buffer/Texture/Pipeline) use this since the GraphicsAPI contract
/// doesn't pass a device to their init functions.
pub fn dev() *Device {
    return global_device.?;
}
